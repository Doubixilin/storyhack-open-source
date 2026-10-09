#!/usr/bin/env python3
"""Compile the audited Storyhack JSONL sources into deterministic runtime shards."""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from typing import Any, Iterable


COMPILER_VERSION = "1.0.0"
SCHEMA_VERSION = 1
MATERIAL_VERSION = "v1"

SOURCE_FILES = (
    "ending_verdicts.jsonl",
    "choices.jsonl",
    "stat_lines.jsonl",
    "prose_samples.jsonl",
    "role_pitches.jsonl",
    "test_inputs.jsonl",
)

GENRES = (
    "dushi", "gufeng", "kehuan", "lishi", "wuxia",
    "wuxianliu", "xianxia", "xiaoyuan", "xihuan", "xuanyi",
)
ARCHETYPES = (
    "chengong", "beiju", "jiliu", "heihua", "zhongpan",
    "pingdan", "kaifang", "lunhui", "xianji", "guajia",
)
FORMS = ("panci", "jintishi", "cipai", "modern", "prose")
SCENES = (
    "duizhi", "tansuo", "gaobai", "taowang", "liangnan", "shenfen",
    "tanpan", "xinren", "fuchou", "xisheng", "zhenxiang", "lichang",
)
DIMENSIONS = (
    "choices_made", "turns", "friends", "enemies", "money", "fame",
    "power", "romances", "betrayals", "deaths", "saves", "kills",
    "places", "secrets", "regrets", "risks", "retreats", "twists",
    "nights", "days",
)
TONES = ("epic", "gentle", "playful", "cold")
STAGES = ("opening", "climax")
ROLE_KINDS = ("canon_hero", "canon_side", "original")
CATEGORIES = (
    "normal", "zuosi", "tiaoju", "nsfw", "nonsense", "overlong",
    "english", "inject", "empty", "emotion",
)
KNOWN_EMOTIONS = (
    "悲壮", "苍凉", "释然", "反讽", "余韵",
    "慰藉", "讥诮", "空茫", "激越", "温婉",
)
FORBIDDEN_PHRASES = (
    "命运的齿轮", "观察眼前线索", "顺势推进",
    "意料之外的行动", "这一刻", "殊不知",
)

NUMBER_PATTERN = re.compile(
    r"[0-9]+(?:[.,][0-9]+)?|[零〇一二两三四五六七八九十百千万亿]+"
)


class CompileError(Exception):
    pass


def _require_string(row: dict[str, Any], key: str, source: str, line: int) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value:
        raise CompileError(f"{source}:{line}: {key} must be a non-empty string")
    return value


def _require_int(row: dict[str, Any], key: str, source: str, line: int) -> int:
    value = row.get(key)
    if not isinstance(value, int) or isinstance(value, bool):
        raise CompileError(f"{source}:{line}: {key} must be an integer")
    return value


def _require_enum(
    row: dict[str, Any], key: str, allowed: Iterable[str], source: str, line: int
) -> str:
    value = _require_string(row, key, source, line)
    if value not in allowed:
        raise CompileError(f"{source}:{line}: invalid {key} {value!r}")
    return value


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise CompileError(f"missing source file: {path}")
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, 1):
            if not raw_line.strip():
                raise CompileError(f"{path.name}:{line_number}: blank JSONL line")
            try:
                value = json.loads(raw_line)
            except json.JSONDecodeError as error:
                raise CompileError(f"{path.name}:{line_number}: invalid JSON: {error}") from error
            if not isinstance(value, dict):
                raise CompileError(f"{path.name}:{line_number}: JSON value must be an object")
            rows.append(value)
    return rows


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _check_type(row: dict[str, Any], expected: str, source: str, line: int) -> None:
    actual = _require_string(row, "type", source, line)
    if actual != expected:
        raise CompileError(f"{source}:{line}: expected type {expected!r}, got {actual!r}")


def _check_forbidden(text: str, source: str, line: int) -> None:
    for phrase in FORBIDDEN_PHRASES:
        if phrase in text:
            raise CompileError(f"{source}:{line}: forbidden phrase {phrase!r}")


def _ensure_minimum_grid(
    counts: collections.Counter[tuple[str, ...]],
    cells: Iterable[tuple[str, ...]],
    minimum: int,
    label: str,
) -> None:
    deficient = [(cell, counts[cell]) for cell in cells if counts[cell] < minimum]
    if deficient:
        cell, count = deficient[0]
        raise CompileError(
            f"{label} grid {cell!r} has {count} rows; minimum is {minimum}"
        )


def _with_id(prefix: str, keys: tuple[str, ...], sequence: int, row: dict[str, Any]) -> dict[str, Any]:
    return {"id": "-".join((prefix, *keys, f"{sequence:04d}")), **row}


def _compile_endings(rows: list[dict[str, Any]], warnings: list[str]) -> dict[str, list[dict[str, Any]]]:
    source = "ending_verdicts.jsonl"
    counters: collections.Counter[tuple[str, str]] = collections.Counter()
    shards = {genre: [] for genre in GENRES}
    unknown_emotions: set[str] = set()
    for line, original in enumerate(rows, 1):
        _check_type(original, "ending_verdict", source, line)
        genre = _require_enum(original, "genre", GENRES, source, line)
        archetype = _require_enum(original, "archetype", ARCHETYPES, source, line)
        _require_enum(original, "form", FORMS, source, line)
        _require_string(original, "form_detail", source, line)
        emotion = _require_string(original, "emotion", source, line)
        text = _require_string(original, "text", source, line)
        _require_string(original, "tension", source, line)
        _require_int(original, "chars", source, line)
        _check_forbidden(text, source, line)
        if emotion not in KNOWN_EMOTIONS:
            unknown_emotions.add(emotion)
        key = (genre, archetype)
        counters[key] += 1
        row = dict(original)
        row["chars"] = len(text)
        shards[genre].append(_with_id("ev", key, counters[key], row))
    _ensure_minimum_grid(
        counters,
        ((genre, archetype) for genre in GENRES for archetype in ARCHETYPES),
        20,
        "ending",
    )
    for emotion in sorted(unknown_emotions):
        warnings.append(f"ending emotion preserved outside canonical list: {emotion}")
    return shards


def _compile_choices(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    source = "choices.jsonl"
    counters: collections.Counter[tuple[str, str]] = collections.Counter()
    shards = {genre: [] for genre in GENRES}
    for line, original in enumerate(rows, 1):
        _check_type(original, "choice", source, line)
        genre = _require_enum(original, "genre", GENRES, source, line)
        scene = _require_enum(original, "scene", SCENES, source, line)
        text = _require_string(original, "text", source, line)
        _require_string(original, "tension", source, line)
        _require_string(original, "stakes", source, line)
        _check_forbidden(text, source, line)
        key = (genre, scene)
        counters[key] += 1
        row = dict(original)
        row["chars"] = len(text)
        shards[genre].append(_with_id("ch", key, counters[key], row))
    _ensure_minimum_grid(
        counters,
        ((genre, scene) for genre in GENRES for scene in SCENES),
        30,
        "choice",
    )
    return shards


def _compile_stats(
    rows: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    source = "stat_lines.jsonl"
    grid: collections.Counter[tuple[str]] = collections.Counter()
    counters: collections.Counter[tuple[str, str]] = collections.Counter()
    accepted: list[dict[str, Any]] = []
    quarantine: list[dict[str, Any]] = []
    for line, original in enumerate(rows, 1):
        _check_type(original, "stat_line", source, line)
        dimension = _require_enum(original, "dimension", DIMENSIONS, source, line)
        tone = _require_enum(original, "tone", TONES, source, line)
        text = _require_string(original, "text", source, line)
        _check_forbidden(text, source, line)
        grid[(dimension,)] += 1
        key = (dimension, tone)
        counters[key] += 1
        material_id = "-".join(("st", *key, f"{counters[key]:04d}"))
        matches = list(NUMBER_PATTERN.finditer(text))
        if len(matches) == 1:
            match = matches[0]
            template = text[:match.start()] + "{n}" + text[match.end():]
            accepted.append({
                "id": material_id,
                "dimension": dimension,
                "tone": tone,
                "template": template,
                "slot": "number",
            })
        else:
            quarantine.append({
                "id": material_id,
                "dimension": dimension,
                "tone": tone,
                "text": text,
                "reason": "numeric_slot_count_" + str(len(matches)),
            })
    _ensure_minimum_grid(grid, ((dimension,) for dimension in DIMENSIONS), 30, "stat")
    return accepted, quarantine


def _compile_prose(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    source = "prose_samples.jsonl"
    grid: collections.Counter[tuple[str]] = collections.Counter()
    counters: collections.Counter[tuple[str, str]] = collections.Counter()
    shards = {genre: [] for genre in GENRES}
    for line, original in enumerate(rows, 1):
        _check_type(original, "prose_sample", source, line)
        genre = _require_enum(original, "genre", GENRES, source, line)
        stage = _require_enum(original, "stage", STAGES, source, line)
        text = _require_string(original, "text", source, line)
        grid[(genre,)] += 1
        key = (genre, stage)
        counters[key] += 1
        row = dict(original)
        row["chars"] = len(text)
        shards[genre].append(_with_id("ps", key, counters[key], row))
    _ensure_minimum_grid(grid, ((genre,) for genre in GENRES), 10, "prose")
    return shards


def _compile_roles(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    source = "role_pitches.jsonl"
    grid: collections.Counter[tuple[str]] = collections.Counter()
    counters: collections.Counter[tuple[str, str]] = collections.Counter()
    shards = {genre: [] for genre in GENRES}
    for line, original in enumerate(rows, 1):
        _check_type(original, "role_pitch", source, line)
        genre = _require_enum(original, "genre", GENRES, source, line)
        role_kind = _require_enum(original, "role_kind", ROLE_KINDS, source, line)
        text = _require_string(original, "text", source, line)
        grid[(genre,)] += 1
        key = (genre, role_kind)
        counters[key] += 1
        row = dict(original)
        row["chars"] = len(text)
        shards[genre].append(_with_id("rp", key, counters[key], row))
    _ensure_minimum_grid(grid, ((genre,) for genre in GENRES), 20, "role")
    return shards


def _compile_test_inputs(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    source = "test_inputs.jsonl"
    counters: collections.Counter[tuple[str]] = collections.Counter()
    output: list[dict[str, Any]] = []
    for line, original in enumerate(rows, 1):
        _check_type(original, "test_input", source, line)
        category = _require_enum(original, "category", CATEGORIES, source, line)
        _require_string(original, "text", source, line)
        _require_string(original, "expected", source, line)
        key = (category,)
        counters[key] += 1
        output.append(_with_id("ti", key, counters[key], dict(original)))
    _ensure_minimum_grid(counters, ((category,) for category in CATEGORIES), 100, "test input")
    return output


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def _compiled_at(output_dir: Path, source_sha256: dict[str, str]) -> str:
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch is not None:
        try:
            instant = dt.datetime.fromtimestamp(int(epoch), tz=dt.timezone.utc)
        except (ValueError, OverflowError) as error:
            raise CompileError("SOURCE_DATE_EPOCH must be an integer Unix timestamp") from error
        return instant.isoformat(timespec="seconds").replace("+00:00", "Z")
    existing = output_dir / "manifest.json"
    try:
        manifest = json.loads(existing.read_text(encoding="utf-8"))
        if manifest.get("source_sha256") == source_sha256 and isinstance(manifest.get("compiled_at"), str):
            return manifest["compiled_at"]
    except (OSError, json.JSONDecodeError):
        pass
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _replace_directory(staged: Path, destination: Path) -> None:
    backup = destination.with_name(destination.name + ".previous")
    if backup.exists():
        shutil.rmtree(backup)
    if destination.exists():
        destination.rename(backup)
    try:
        staged.rename(destination)
    except Exception:
        if backup.exists() and not destination.exists():
            backup.rename(destination)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def compile_materials(source_dir: Path, output_dir: Path, fixtures_path: Path) -> dict[str, Any]:
    if source_dir.name in {"final", "parts"}:
        raise CompileError("source directory must be the storyhack_materials root")
    paths = {name: source_dir / name for name in SOURCE_FILES}
    source_sha256 = {name: _sha256(path) for name, path in paths.items() if path.is_file()}
    missing = [name for name in SOURCE_FILES if name not in source_sha256]
    if missing:
        raise CompileError("missing source files: " + ", ".join(missing))

    raw = {name: _load_jsonl(path) for name, path in paths.items()}
    warnings: list[str] = []
    endings = _compile_endings(raw["ending_verdicts.jsonl"], warnings)
    choices = _compile_choices(raw["choices.jsonl"])
    stats, stats_quarantine = _compile_stats(raw["stat_lines.jsonl"])
    prose = _compile_prose(raw["prose_samples.jsonl"])
    roles = _compile_roles(raw["role_pitches.jsonl"])
    test_inputs = _compile_test_inputs(raw["test_inputs.jsonl"])

    package_counts = {
        "ending_verdicts": sum(map(len, endings.values())),
        "choices": sum(map(len, choices.values())),
        "stat_lines": len(raw["stat_lines.jsonl"]),
        "stat_templates": len(stats),
        "stat_quarantine": len(stats_quarantine),
        "prose_samples": sum(map(len, prose.values())),
        "role_pitches": sum(map(len, roles.values())),
        "test_inputs": len(test_inputs),
    }
    shards = {
        "ending": {genre: len(endings[genre]) for genre in GENRES},
        "choices": {genre: len(choices[genre]) for genre in GENRES},
        "prose": {genre: len(prose[genre]) for genre in GENRES},
        "roles": {genre: len(roles[genre]) for genre in GENRES},
    }
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "material_version": MATERIAL_VERSION,
        "compiled_at": _compiled_at(output_dir, source_sha256),
        "compiler_version": COMPILER_VERSION,
        "package_counts": package_counts,
        "source_sha256": source_sha256,
        "shards": shards,
        "warnings": warnings,
    }

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    staged = Path(tempfile.mkdtemp(prefix="materials-v1.", dir=output_dir.parent))
    try:
        _write_json(staged / "manifest.json", manifest)
        for genre in GENRES:
            _write_json(staged / "ending" / f"{genre}.json", endings[genre])
            _write_json(staged / "choices" / f"{genre}.json", choices[genre])
            _write_json(staged / "prose" / f"{genre}.json", prose[genre])
            _write_json(staged / "roles" / f"{genre}.json", roles[genre])
        _write_json(staged / "stats.json", stats)
        _write_json(staged / "stats_quarantine.json", stats_quarantine)
        _replace_directory(staged, output_dir)
    finally:
        if staged.exists():
            shutil.rmtree(staged)

    fixtures_path.parent.mkdir(parents=True, exist_ok=True)
    staged_fixture = fixtures_path.with_suffix(fixtures_path.suffix + ".tmp")
    _write_jsonl(staged_fixture, test_inputs)
    staged_fixture.replace(fixtures_path)
    return manifest


def _default_paths(repo_root: Path) -> tuple[Path, Path, Path]:
    source = repo_root / "Materials/source"
    output = repo_root / "Sources/StoryMaterialKit/Resources/materials-v1"
    fixture = repo_root / "Tests/StoryMaterialKitTests/Fixtures/test_inputs.jsonl"
    return source, output, fixture


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    default_source, default_output, default_fixture = _default_paths(repo_root)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=default_source)
    parser.add_argument("--output-dir", type=Path, default=default_output)
    parser.add_argument("--fixtures-path", type=Path, default=default_fixture)
    args = parser.parse_args()
    try:
        manifest = compile_materials(args.source_dir, args.output_dir, args.fixtures_path)
    except (CompileError, OSError) as error:
        print(f"material compiler failed: {error}", file=os.sys.stderr)
        return 1
    print(json.dumps(manifest["package_counts"], ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
