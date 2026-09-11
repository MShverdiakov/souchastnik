# Changelog

Формат близкий к [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).
Версии приложения по `versionName` в `app/build.gradle.kts`.

## Unreleased

Hexagon NPU на Snapdragon и кэш системного префикса промпта. Качество вердиктов
на контрольном наборе BenchActivity не изменилось (7/11). Закрывает
[issue #5](https://github.com/MShverdiakov/souchastnik/issues/5).

### Добавлено

#### Offload слоёв на Hexagon HTP (NPU)

- Сборка llama.cpp с `-DGGML_HEXAGON=ON`, если задан Hexagon SDK
  (`hexagon.sdk.dir` в `local.properties` или `HEXAGON_SDK_ROOT`). OpenCL / Adreno
  не включаются.
- В APK попадают `libggml-hexagon.so` (ARM-хост) и DSP-skel
  `libggml-htp-v{73,75,79,81}.so`. Skel — ELF DSP, не ARM: `llvm-strip` их ломает,
  поэтому они в `keepDebugSymbols`, как модель.
- Skel копируются из каталога ExternalProject в `CMAKE_LIBRARY_OUTPUT_DIRECTORY`
  (`copy_htp_skels.cmake`), иначе AGP не кладёт их в APK.
- В манифесте `uses-native-library` на `libcdsprpc.so` / `libadsprpc.so`
  (`required=false`): FastRPC живёт в `/vendor/lib64`, в APK не кладём, без этого
  узла линкер приложения её не видит из-за namespace.
- Перед `init` HTP-skel копируются в `filesDir/htp` с режимом 0644
  (`LlamaBridge.stageHtpSkels`). CDSP читает файл из другого процесса и часто не
  видит `/data/app/.../lib/arm64` из-за SELinux. `ADSP_LIBRARY_PATH` указывает
  и на `nativeLibraryDir`, и на эту копию, и на системные DSP-пути.
- `n_gpu_layers = -1` (все слои, которые Hexagon умеет). Нет HTP-устройства,
  нет `libggml-hexagon.so`, или контекст с NPU не поднялся — тот же CPU-путь,
  что был раньше. `backendName()` вида `android_armv8.6_1+HTP0` или `…+cpu`.
- Без Hexagon SDK проект собирается как раньше, только CPU. На устройстве без
  Snapdragon HTP рантайм тоже уходит на CPU.

#### Кэш системного префикса

Системное сообщение судьи (`Articles.judgeSystem`) зависит от набора статей, но
пока человек дописывает одну фразу, набор не меняется. Раньше каждый `decide()`
префиллил ~300 токенов системки заново.

- После префилла `head = TPL_SYS_OPEN + system + TPL_SYS_CLOSE` снимок seq-state
  кладётся в RAM (`llama_state_seq_get_data_ext`, флаги `NONE` — копия на хосте,
  ~20 МБ KV + Gated DeltaNet).
- Следующий запрос с тем же `head` восстанавливает снимок и префиллит только
  user-текст + хвост шаблона. После restore проверяется
  `llama_memory_seq_pos_max == head.size() - 1`; иначе кэш сбрасывается и идёт
  полный префилл.
- Флаги `ON_DEVICE` не используются: у гибридной Qwen3.5 (18/24 слоя — DeltaNet)
  несколько диапазонов ячеек на DSP дают `GGML_ABORT`.
- API `EngineService` / `decide()` не менялся: кэш живёт на нативном `Engine`.
- Пятый элемент `stats` (если массив длиннее 4) — `1` при HIT.

#### BenchActivity (только debug)

- `--ez cpu true` — A/B без HTP.
- Колонка HIT/miss и блок «набор одной фразы»: три растущих префикса одной
  реплики, чтобы увидеть кэш так, как его чувствует клавиатура.

### Изменено

- Пин llama.cpp: `85c55223` (b10726) → `5bda51bf` (есть ggml-hexagon и ядро
  `GGML_OP_GATED_DELTA_NET`). Дерево по-прежнему в `.gitignore`.
- CMake для AGP: 3.22.1 → 3.31.6 (`htp/CMakeLists.txt` требует ≥ 3.22.2).
- После checkout пина нужен патч
  `tools/patches/llama.cpp-hexagon-ninja.patch`: во вложенный cmake HTP
  прокидывается `-DCMAKE_MAKE_PROGRAM`, иначе nested cmake не находит ninja.

### Замеры на Galaxy S25 (SM-S931B, SM8750, Hexagon v79, 2 host-потока)

Контрольный набор BenchActivity, та же модель Q4_0, что в релизе 1.0.
Вердикты **7/11** во всех трёх колонках.

| | CPU, пин b10726 | CPU, новый пин | HTP | HTP + HIT кэша |
|---|---|---|---|---|
| Медиана полного префилла | 983 мс | 3893 мс | ~468–484 мс | — |
| Повторный набор той же фразы | тот же полный префилл | тот же | ~680 мс miss | **74–90 мс** |

Новый llama.cpp на чистом CPU заметно медленнее b10726. На Snapdragon с HTP
это скрыто offload’ом; на телефонах без NPU скорость разбора на новом пине
хуже, пока не вернёмся на старый пин или не появится более быстрый CPU-бэкенд.

6 host-потоков и `flash_attn ENABLED` на HTP дали graph splits=39 и медиану
1.3–1.7 с — **не включать**.

### Сборка NPU

Нужны Hexagon SDK 6.6.0.0 и CMake 3.31.6 из Android SDK. В `local.properties`:

```
hexagon.sdk.dir=/path/to/hexagon/6.6.0.0
```

Пин llama.cpp:

```
git clone https://github.com/ggml-org/llama.cpp third_party/llama.cpp
git -C third_party/llama.cpp checkout 5bda51bfbc62e64193221e639f6ad4e08767d760
git -C third_party/llama.cpp apply ../../tools/patches/llama.cpp-hexagon-ninja.patch
```

`libcdsprpc.so` в APK не кладётся — это системная библиотека Qualcomm.

### Ограничения

- NPU есть у Snapdragon с Hexagon HTP (на S25 — v79). MediaTek / Exynos / Kirin
  остаются на CPU.
- Кэш срабатывает, пока не сменился набор статей-кандидатов. Разные статьи —
  разная системка — miss и полный префилл head.
- Тяжелее модель в этот PR не берём: сначала скорость текущей Qwen3.5-0.8B Q4_0.
