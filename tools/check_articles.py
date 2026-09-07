#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Проверка инвариантов справочника и словаря триггеров.

Ловит ровно ту поломку, из-за которой 24 статьи месяц лежали мёртвым
грузом: статья, которой нет ни в одной группе triggers.json, недостижима.
Triggers.match возвращает объединение кодов сработавших групп, и в
кандидаты такая статья не попадает НИКОГДА -- ни модель, ни строка её не
увидят. Обратная поломка тише и хуже: если группа ссылается на код,
которого в articles.json нет, Articles.judgeSystem молча пропустит его
через mapNotNull, и группа будет поднимать на одного кандидата меньше,
чем написано в файле.

Запуск из корня репозитория:

    python3 -X utf8 tools/check_articles.py /path/to/original/assets

Код возврата 1, если хоть один инвариант нарушен -- годится для хука.
"""

import json
import sys
from pathlib import Path

ASSETS = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("Data/Private")


def load(name):
    with open(ASSETS / name, encoding="utf-8") as f:
        return json.load(f)


def main():
    articles = load("articles.json")
    triggers = load("triggers.json")
    agents = load("agents.json")

    arts = articles["articles"]
    codes = [a["code"] for a in arts]
    groups = triggers["groups"]

    referenced = set()
    for g in groups:
        referenced.update(g["codes"])

    problems = []

    unreachable = [c for c in codes if c not in referenced]
    if unreachable:
        problems.append(
            "недостижимы (нет ни в одной группе triggers.json): "
            + ", ".join(unreachable)
        )

    dangling = sorted(referenced - set(codes))
    if dangling:
        problems.append(
            "группы ссылаются на статьи, которых нет в articles.json: "
            + ", ".join(dangling)
        )

    dupes = sorted({c for c in codes if codes.count(c) > 1})
    if dupes:
        problems.append("код статьи повторяется: " + ", ".join(dupes))

    # Метки приложение НЕ читает: судья отвечает кодом статьи. Но поле живое
    # для десктопа -- try.py берёт _none_label в __init__ в любом режиме,
    # bench_variants.py строит на метках вариант «все статьи в фиксированном
    # промпте», и на них же весь train/. Дубль метки там сливает две статьи
    # в одну молча, поэтому проверяем.
    labels = [a["label"] for a in arts]
    label_dupes = sorted({l for l in labels if labels.count(l) > 1})
    if label_dupes:
        problems.append("метка повторяется: " + ", ".join(label_dupes))
    if articles["_none_label"] in labels:
        problems.append(
            "_none_label совпадает с меткой статьи: " + articles["_none_label"]
        )

    # У каждой группы обязан быть чистый контрпример: при сработке он уходит
    # в промпт рядом с положительным примером, без него «поздравляю с 9 мая»
    # давало 354.1.
    for i, g in enumerate(groups):
        if not g.get("clean"):
            problems.append("группа %d (%s) без clean" % (i + 1, g.get("hint", "?")))

    # Шаблон пометки выбирается полем kind; отсутствующий kind -- это
    # IllegalStateException в Agents.load уже на старте клавиатуры.
    kinds = set(agents["templates"])
    for section in ("agents", "services"):
        for e in agents[section]:
            if e.get("kind", "agent") not in kinds:
                problems.append(
                    "%s: kind=%s без шаблона" % (e["name"], e.get("kind"))
                )
            if not (e.get("forms") or e.get("exact")):
                problems.append("%s: ни forms, ни exact" % e["name"])

    print("статей: %d, групп триггеров: %d, покрыто кодов: %d" % (
        len(codes), len(groups), len(referenced)))
    print("иноагентов: %d, сервисов: %d" % (
        len(agents["agents"]), len(agents["services"])))

    if problems:
        print()
        for p in problems:
            print("ПЛОХО: " + p)
        return 1
    print("все инварианты выполнены")
    return 0


if __name__ == "__main__":
    sys.exit(main())
