import argparse
import os
import time

import torch
from compressed_tensors.offload import dispatch_model
from compressed_tensors.quantization import preset_name_to_scheme
from datasets import load_dataset
from transformers import AutoModelForCausalLM, AutoTokenizer

# Monkey-patch os.chmod to ignore permission errors on shared cache
_original_chmod = os.chmod
def _chmod_ignore_errors(path, mode):
    try:
        _original_chmod(path, mode)
    except PermissionError:
        pass  # Silently ignore chmod errors on shared cache files
os.chmod = _chmod_ignore_errors

from llmcompressor import oneshot
from llmcompressor.modifiers.gptq import GPTQModifier
from llmcompressor.modifiers.quantization import QuantizationModifier
from llmcompressor.modifiers.transform.awq import AWQModifier
from llmcompressor.modifiers.transform.awq.dynamic_mappings import (
    get_layer_mappings_from_model,
)
from llmcompressor.modifiers.transform.imatrix import IMatrixGatherer
from llmcompressor.modifiers.transform.smoothquant import SmoothQuantModifier

MODEL_CONFIGS = {
    "Qwen/Qwen2.5-3B-Instruct": {
        "ignore": ["lm_head"],
        "is_moe": False,
    },
    "meta-llama/Meta-Llama-3-8B-Instruct": {
        "ignore": ["lm_head"],
        "is_moe": False,
    },
    "Qwen/Qwen3-30B-A3B": {
        "ignore": ["lm_head", "re:.*mlp.gate$", "re:.*mlp.shared_expert_gate$"],
        "is_moe": True,
    },
    "Qwen/Qwen1.5-MoE-A2.7B-Chat": {
        "ignore": ["lm_head", "re:.*mlp.gate$", "re:.*mlp.shared_expert_gate$"],
        "is_moe": True,
    },
    "google/gemma-4-12B-it": {
        "ignore": [
            "lm_head",
            "re:.*embed_vision.*",
            "re:.*embed_audio.*",
            "re:.*vision_embedder.*",
        ],
        "is_moe": False,
    },
    "meta-llama/Llama-4-Scout-17B-16E-Instruct": {
        "ignore": [
            "re:.*lm_head",
            "re:.*router",
            "re:.*self_attn.*",
            "re:.*shared_expert.*",
            "re:multi_modal_projector.*",
            "re:vision_model",
        ],
        "is_moe": True,
        "model_class": "Llama4ForConditionalGeneration",
    },
    "Qwen/Qwen3.5-27B": {
        "ignore": [
            "lm_head",
            "re:.*visual.*",
            "re:.*linear_attn.*",
        ],
        "is_moe": False,
        "model_class": "Qwen3_5ForConditionalGeneration",
    },
}

DATASET_ID = "HuggingFaceH4/ultrachat_200k"
DATASET_SPLIT = "train_sft"


def build_recipe(technique, scheme, ignore, is_moe, model=None):
    if technique in ("awq_rtn", "awq_smooth", "awq_no_up_down"):
        # duo_scaling only works with per-channel strategies (GROUP, CHANNEL)
        # FP8 uses TENSOR strategy, so disable duo_scaling for it
        if "FP8" in scheme or is_moe:
            duo = False
        else:
            duo = "both"

        awq_kwargs = {"duo_scaling": duo}

        if technique == "awq_smooth":
            awq_kwargs["smooth_layer_quantization"] = True
        elif technique == "awq_no_up_down":
            mappings = get_layer_mappings_from_model(model)
            mappings = [
                m
                for m in mappings
                if not any("down_proj" in bl for bl in m.balance_layers)
            ]
            awq_kwargs["mappings"] = mappings

        return [
            AWQModifier(**awq_kwargs),
            QuantizationModifier(
                ignore=ignore, scheme=scheme, targets=["Linear"]
            ),
        ]
    elif technique == "rtn":
        return [
            QuantizationModifier(
                ignore=ignore, scheme=scheme, targets=["Linear"]
            ),
        ]
    elif technique == "rtn_mse":
        scheme_obj = preset_name_to_scheme(scheme, ["Linear"])
        scheme_obj.weights.observer = "memoryless_mse"
        return [
            QuantizationModifier(
                config_groups={"group_0": scheme_obj},
                ignore=ignore,
            ),
        ]
    elif technique == "gptq":
        recipe = []
        if "W8A8" in scheme:
            recipe.append(SmoothQuantModifier(smoothing_strength=0.8))
        recipe.append(
            GPTQModifier(ignore=ignore, scheme=scheme, targets=["Linear"])
        )
        return recipe
    elif technique == "imatrix":
        scheme_obj = preset_name_to_scheme(scheme, ["Linear"])
        scheme_obj.weights.observer = "imatrix_mse"
        return [
            IMatrixGatherer(ignore=ignore),
            QuantizationModifier(
                config_groups={"group_0": scheme_obj},
                ignore=ignore,
            ),
        ]
    else:
        raise ValueError(f"Unknown technique: {technique}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument(
        "--technique", required=True,
        choices=["awq_rtn", "awq_smooth", "awq_no_up_down", "rtn", "rtn_mse", "gptq", "imatrix"],
    )
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--save-dir", required=True)
    parser.add_argument("--num-samples", type=int, default=256)
    parser.add_argument("--max-seq-length", type=int, default=512)
    args = parser.parse_args()

    config = MODEL_CONFIGS.get(args.model)
    if config is None:
        raise ValueError(
            f"Unknown model: {args.model}. "
            f"Known models: {list(MODEL_CONFIGS.keys())}"
        )

    model_class_name = config.get("model_class")
    if model_class_name:
        import transformers
        model_class = getattr(transformers, model_class_name)
        model = model_class.from_pretrained(args.model, dtype="auto")
        from transformers import AutoProcessor
        processor = AutoProcessor.from_pretrained(args.model)
        tokenizer = getattr(processor, "tokenizer", processor)
    else:
        model = AutoModelForCausalLM.from_pretrained(args.model, dtype="auto")
        tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)

    ds = load_dataset(DATASET_ID, split=f"{DATASET_SPLIT}[:{args.num_samples}]")
    ds = ds.shuffle(seed=42)

    def preprocess(example):
        return {
            "text": tokenizer.apply_chat_template(
                example["messages"],
                tokenize=False,
            )
        }

    ds = ds.map(preprocess)

    def tokenize(sample):
        return tokenizer(
            sample["text"],
            padding=False,
            max_length=args.max_seq_length,
            truncation=True,
            add_special_tokens=False,
        )

    ds = ds.map(tokenize, remove_columns=ds.column_names)

    recipe = build_recipe(
        args.technique, args.scheme, config["ignore"], config["is_moe"], model=model
    )

    torch.cuda.reset_peak_memory_stats()
    start_time = time.time()

    oneshot_kwargs = dict(
        model=model,
        dataset=ds,
        recipe=recipe,
        max_seq_length=args.max_seq_length,
        num_calibration_samples=args.num_samples,
    )

    oneshot(**oneshot_kwargs)

    elapsed_time = time.time() - start_time
    peak_memory_gb = torch.cuda.max_memory_allocated() / (1024**3)
    print("Quantization Complete")
    print(f"Technique: {args.technique}, Scheme: {args.scheme}")
    print(f"Time: {elapsed_time / 60:.2f} minutes ({elapsed_time:.2f} seconds)")
    print(f"Peak GPU Memory: {peak_memory_gb:.2f} GB")

    model.save_pretrained(args.save_dir, save_compressed=True)
    tokenizer.save_pretrained(args.save_dir)

    try:
        from transformers import AutoProcessor
        processor = AutoProcessor.from_pretrained(args.model)
        processor.save_pretrained(args.save_dir)
        print(f"Processor saved to {args.save_dir}")
    except Exception:
        pass

    print(f"Model saved to {args.save_dir}")


if __name__ == "__main__":
    main()
