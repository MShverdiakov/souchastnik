#!/usr/bin/env bash
# Сборка GGUF для телефона: merge LoRA -> f16 GGUF -> imatrix -> Q4_0.
#
# Нужны llama.cpp и питон с transformers/peft.
#   bash tools/make_gguf.sh path/to/lora-adapter
set -euo pipefail

ADAPTER="${1:?укажи каталог с LoRA-адаптером}"
BASE="Qwen/Qwen3.5-0.8B-Base"
LLAMA="${LLAMA_CPP:-third_party/llama.cpp}"
WORK="build/model"
RU_CORPUS="${RU_CORPUS:-tools/imatrix-ru.txt}"

mkdir -p "$WORK"

echo "== 1/4 merge LoRA в базовую модель =="
python - "$ADAPTER" "$BASE" "$WORK/merged" <<'PY'
import sys
import torch
from peft import PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer

adapter, base, out = sys.argv[1:4]
model = AutoModelForCausalLM.from_pretrained(base, torch_dtype=torch.bfloat16,
                                             trust_remote_code=True)
model = PeftModel.from_pretrained(model, adapter)
model = model.merge_and_unload()
model.save_pretrained(out)
AutoTokenizer.from_pretrained(adapter).save_pretrained(out)
print("смержено в", out)
PY

echo "== 2/4 конвертация в GGUF f16 =="
# Визуальная башня не нужна: приложение работает только с текстом.
# llama.cpp выносит её в отдельный mmproj-файл, который мы просто не собираем.
python "$LLAMA/convert_hf_to_gguf.py" "$WORK/merged" \
    --outfile "$WORK/souchastnik-f16.gguf" \
    --outtype f16

echo "== 3/4 матрица важности на РУССКОМ тексте =="
# Критично. У 0.8B при Q4 запаса качества нет, и imatrix, посчитанная на
# дефолтном англоязычном корпусе, просаживает именно русский -- то есть
# ровно то, ради чего эта модель и выбрана.
if [ ! -f "$RU_CORPUS" ]; then
    echo "НЕТ русского корпуса: $RU_CORPUS"
    echo "Положи туда 2-5 МБ живого русского текста (переписки, форумы,"
    echo "не литературу) и запусти снова."
    exit 1
fi
"$LLAMA/build/bin/llama-imatrix" \
    -m "$WORK/souchastnik-f16.gguf" \
    -f "$RU_CORPUS" \
    -o "$WORK/souchastnik.imatrix" \
    --chunks 200

echo "== 4/4 квантизация Q4_0 (на ARM с dotprod у Q4_0 есть repack-ядра, у K-квантов нет; см. LlamaBridge.MODEL_LIB) =="
"$LLAMA/build/bin/llama-quantize" \
    --imatrix "$WORK/souchastnik.imatrix" \
    "$WORK/souchastnik-f16.gguf" \
    "$WORK/souchastnik-qwen35-08b-q40.gguf" \
    Q4_0

ls -la "$WORK/souchastnik-qwen35-08b-q40.gguf"
echo
echo "Готово. Импортируйте GGUF в iOS-приложении на вкладке Словари."
