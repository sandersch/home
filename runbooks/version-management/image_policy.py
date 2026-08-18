#!/usr/bin/env python3
"""Inventory and validate repo-authored container image references."""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}$")
REFERENCE_RE = re.compile(
    r"^(?P<repository>[A-Za-z0-9._-]+(?:/[A-Za-z0-9._/-]+)*)"
    r"(?::(?P<tag>[A-Za-z0-9_][A-Za-z0-9._-]*))?"
    r"(?:@(?P<digest>sha256:[A-Za-z0-9]+))?$"
)
FLOATING_TAGS = {
    "latest",
    "stable",
    "edge",
    "main",
    "master",
    "nightly",
    "canary",
    "dev",
    "develop",
    "release",
}
RENOVATE_RE = re.compile(r"#\s*renovate:\s+.*\bdepName=(?P<name>\S+)")
UPSTREAM_VERSION_RE = re.compile(r"#\s*upstream-version:\s*\S+")


@dataclass(frozen=True)
class ImageReference:
    path: Path
    line: int
    source_type: str
    raw: str
    repository: str
    tag: str
    digest: str


def normalize_repository(repository: str) -> str:
    first = repository.split("/", 1)[0]
    if "." not in first and ":" not in first and first != "localhost":
        if "/" not in repository:
            return f"docker.io/library/{repository}"
        return f"docker.io/{repository}"
    return repository


def parse_reference(raw: str) -> tuple[str, str, str] | None:
    raw = raw.strip().strip("'\"")
    match = REFERENCE_RE.fullmatch(raw)
    if not match:
        return None
    return (
        normalize_repository(match.group("repository")),
        match.group("tag") or "",
        match.group("digest") or "",
    )


def candidate_files(root: Path) -> list[Path]:
    candidates: set[Path] = set()
    for directory in ("apps", "infrastructure", "containers"):
        base = root / directory
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.is_file():
                candidates.add(path)

    runbooks = root / "runbooks"
    if runbooks.exists():
        for path in runbooks.rglob("*"):
            if not path.is_file():
                continue
            relative = path.relative_to(root)
            if relative.parts[:2] == ("runbooks", "version-management") and "fixtures" in relative.parts:
                continue
            if os.access(path, os.X_OK) or path.suffix == ".sh":
                candidates.add(path)

    return sorted(candidates)


def annotation_name(lines: list[str], index: int) -> str:
    for comment_index in (index, index - 1, index - 2):
        if comment_index < 0:
            continue
        match = RENOVATE_RE.search(lines[comment_index])
        if match:
            return normalize_repository(match.group("name"))
    return ""


def has_upstream_version(lines: list[str], index: int) -> bool:
    return any(
        comment_index >= 0 and UPSTREAM_VERSION_RE.search(lines[comment_index])
        for comment_index in (index, index - 1, index - 2)
    )


def add_reference(
    references: list[ImageReference],
    path: Path,
    line_number: int,
    source_type: str,
    raw: str,
) -> None:
    parsed = parse_reference(raw)
    if parsed is None:
        references.append(
            ImageReference(path, line_number, source_type, raw, "", "", "")
        )
        return
    repository, tag, digest = parsed
    references.append(
        ImageReference(path, line_number, source_type, raw, repository, tag, digest)
    )


def scan_file(
    root: Path, path: Path, known_variables: dict[str, str]
) -> tuple[list[ImageReference], list[str]]:
    relative = path.relative_to(root)
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return [], []
    if re.search(r"^\s*sops:\s*$", text, re.MULTILINE):
        return [], []

    lines = text.splitlines()
    references: list[ImageReference] = []
    errors: list[str] = []
    variables = dict(known_variables)
    is_containerfile = path.name in {"Containerfile", "Dockerfile"} or path.name.endswith(
        (".Containerfile", ".Dockerfile")
    )
    is_shell = lines[:1] and "sh" in lines[0]

    for index, line in enumerate(lines):
        line_number = index + 1
        assignment = re.search(
            r"^(?:export\s+)?(?P<name>[A-Z][A-Z0-9_]*IMAGE)=(?P<ref>[^\s#]+)",
            line.strip(),
        )
        if assignment:
            variables[assignment.group("name")] = assignment.group("ref")
            add_reference(
                references,
                relative,
                line_number,
                "shell-variable",
                assignment.group("ref"),
            )
            annotation = annotation_name(lines, index)
            parsed = parse_reference(assignment.group("ref"))
            if parsed and annotation != parsed[0]:
                errors.append(
                    f"{relative}:{line_number}: shell image variable requires an adjacent "
                    f"'# renovate: datasource=docker depName={parsed[0]}' annotation"
                )
            continue

        if is_containerfile:
            match = re.search(r"^\s*FROM\s+(?:--platform=\S+\s+)?(?P<ref>\S+)", line)
            if match and match.group("ref").lower() != "scratch":
                add_reference(references, relative, line_number, "containerfile", match.group("ref"))
            continue

        image_match = re.search(r"^\s*image:\s*(?P<ref>[^\s#]+)", line)
        if image_match:
            raw = image_match.group("ref").strip("'\"")
            variable_match = re.fullmatch(r"\$(?:\{)?(?P<name>[A-Z][A-Z0-9_]*IMAGE)(?:\})?", raw)
            if variable_match:
                name = variable_match.group("name")
                if name != "RECOVERY_IMAGE" or name not in variables:
                    errors.append(f"{relative}:{line_number}: unapproved or unresolved image indirection {raw}")
                else:
                    add_reference(
                        references,
                        relative,
                        line_number,
                        "shell-indirect",
                        variables[name],
                    )
            else:
                add_reference(
                    references,
                    relative,
                    line_number,
                    "shell-heredoc" if is_shell else "kubernetes",
                    raw,
                )
                if is_shell:
                    parsed = parse_reference(raw)
                    annotation = annotation_name(lines, index)
                    if parsed and annotation != parsed[0]:
                        errors.append(
                            f"{relative}:{line_number}: shell/heredoc image requires an adjacent "
                            f"'# renovate: datasource=docker depName={parsed[0]}' annotation"
                        )
            continue

        kubectl_match = re.search(r"--image(?:=|\s+)(?P<ref>[^\s\\]+)", line)
        if kubectl_match:
            raw = kubectl_match.group("ref").strip("'\"")
            add_reference(references, relative, line_number, "kubectl", raw)
            parsed = parse_reference(raw)
            annotation = annotation_name(lines, index)
            if parsed and annotation != parsed[0]:
                errors.append(
                    f"{relative}:{line_number}: kubectl image requires an adjacent "
                    f"'# renovate: datasource=docker depName={parsed[0]}' annotation"
                )
            continue

        assertion = re.search(r"\.image\s*==\s*[\"'](?P<ref>[^\"']+)[\"']", line)
        if assertion:
            raw = assertion.group("ref")
            add_reference(references, relative, line_number, "shell-assertion", raw)
            parsed = parse_reference(raw)
            annotation = annotation_name(lines, index)
            if parsed and annotation != parsed[0]:
                errors.append(
                    f"{relative}:{line_number}: image assertion requires an adjacent "
                    f"'# renovate: datasource=docker depName={parsed[0]}' annotation"
                )

    for reference in references:
        prefix = f"{reference.path}:{reference.line}"
        if not reference.repository:
            errors.append(f"{prefix}: malformed image reference {reference.raw!r}")
            continue
        if not reference.digest:
            errors.append(f"{prefix}: image must include an immutable sha256 digest")
        elif not DIGEST_RE.fullmatch(reference.digest):
            errors.append(f"{prefix}: malformed digest {reference.digest!r}")
        if reference.tag:
            lowered = reference.tag.lower()
            if lowered in FLOATING_TAGS:
                errors.append(f"{prefix}: floating channel tag {reference.tag!r} is forbidden")
            if re.fullmatch(r"v?\d+(?:\.\d+)?(?:-(?:alpine|bookworm|bullseye|noble|trixie))?", lowered):
                errors.append(f"{prefix}: floating major/minor tag {reference.tag!r} is forbidden")
        elif not has_upstream_version(lines, reference.line - 1):
            errors.append(
                f"{prefix}: digest-only image requires an adjacent '# upstream-version: ...' comment"
            )

    return references, errors


def scan(root: Path) -> tuple[list[ImageReference], list[str]]:
    references: list[ImageReference] = []
    errors: list[str] = []
    files = candidate_files(root)
    known_variables: dict[str, str] = {}
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for match in re.finditer(
            r"^(?:export\s+)?(?P<name>[A-Z][A-Z0-9_]*IMAGE)=(?P<ref>[^\s#]+)",
            text,
            re.MULTILINE,
        ):
            known_variables[match.group("name")] = match.group("ref")

    for path in files:
        found, file_errors = scan_file(root, path, known_variables)
        references.extend(found)
        errors.extend(file_errors)

    by_repository: dict[str, set[str]] = {}
    for reference in references:
        if reference.repository and reference.digest:
            by_repository.setdefault(reference.repository, set()).add(reference.raw)
    for repository, raw_references in sorted(by_repository.items()):
        if len(raw_references) > 1:
            errors.append(
                f"coupled-reference drift for {repository}: {', '.join(sorted(raw_references))}"
            )

    version_file = root / "containers/restic-backup/VERSION"
    if version_file.exists():
        version = version_file.read_text(encoding="utf-8").strip()
        custom = [
            reference
            for reference in references
            if reference.repository == "ghcr.io/sandersch/restic-backup"
        ]
        if not custom:
            errors.append("containers/restic-backup/VERSION exists but no custom Restic image references were found")
        for reference in custom:
            if reference.tag != version:
                errors.append(
                    f"{reference.path}:{reference.line}: custom Restic tag {reference.tag!r} "
                    f"does not match VERSION {version!r}"
                )

    return references, sorted(set(errors))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("inventory", "check"), nargs="?", default="inventory")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    root = args.root.resolve()
    references, errors = scan(root)
    if not args.quiet:
        print("file\tline\tsource\trepository\ttag\tdigest")
        for reference in references:
            print(
                f"{reference.path}\t{reference.line}\t{reference.source_type}\t"
                f"{reference.repository}\t{reference.tag}\t{reference.digest}"
            )

    if args.mode == "check" and errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
