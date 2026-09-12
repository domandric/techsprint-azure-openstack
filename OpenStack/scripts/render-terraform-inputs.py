#!/usr/bin/env python3
"""Render the operator CSV into the small, typed input contract Terraform uses."""

from __future__ import print_function

import argparse
import csv
import io
import json
import os
import re
import sys
import tempfile
import unicodedata


SLUG_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# These are deliberately finite rather than a fuzzy role parser.  Header
# aliases are handled separately below; values must be one of these spellings.
ROLE_VALUES = {
    "developer": "developer",
    "dev": "developer",
    "devops_lead": "devops_lead",
    "devops": "devops_lead",
    "devops-lead": "devops_lead",
    "devops lead": "devops_lead",
    "devopslead": "devops_lead",
    "lead": "devops_lead",
}

HEADER_ALIASES = {
    "first_name": "first_name",
    "last_name": "last_name",
    "role": "role",
    "email": "email",
    "ime": "first_name",
    "prezime": "last_name",
    "rola": "role",
    "uloga": "role",
}

# NFKD handles Latin diacritics (including Croatian).  This small table keeps
# common non-Latin names deterministic without making an external dependency
# part of the deployment wrapper.
TRANSLITERATION = {
    "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Ђ": "Dj",
    "Е": "E", "Ё": "E", "Ж": "Zh", "З": "Z", "И": "I", "Й": "J",
    "К": "K", "Л": "L", "Љ": "Lj", "М": "M", "Н": "N", "Њ": "Nj",
    "О": "O", "П": "P", "Р": "R", "С": "S", "Т": "T", "Ћ": "C",
    "У": "U", "Ф": "F", "Х": "H", "Ц": "Ts", "Ч": "Ch", "Џ": "Dz",
    "Ш": "Sh", "Щ": "Shch", "Ъ": "", "Ы": "Y", "Ь": "", "Э": "E",
    "Ю": "Yu", "Я": "Ya",
}
TRANSLITERATION.update({key.lower(): value.lower() for key, value in list(TRANSLITERATION.items())})


def fail(message):
    raise ValueError(message)


def clean(value):
    return value.strip() if value is not None else ""


def choose_delimiter(text):
    sample = "\n".join(line for line in text.splitlines() if line.strip())
    if not sample:
        fail("CSV input is empty")
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=";,")
        return dialect.delimiter
    except csv.Error:
        first_line = sample.splitlines()[0]
        semicolons = first_line.count(";")
        commas = first_line.count(",")
        if semicolons == commas == 0 or semicolons == commas:
            fail("could not determine whether the CSV delimiter is ';' or ','")
        return ";" if semicolons > commas else ","


def transliterate(value):
    decomposed = unicodedata.normalize("NFKD", value)
    pieces = []
    for character in decomposed:
        if unicodedata.combining(character):
            continue
        pieces.append(TRANSLITERATION.get(character, character))
    return "".join(pieces)


def make_slug(first_name, last_name):
    source = transliterate(first_name + " " + last_name).lower()
    source = re.sub(r"[^a-z0-9]+", "-", source)
    source = re.sub(r"-+", "-", source).strip("-")
    if not SLUG_RE.match(source):
        fail("names {!r} and {!r} do not produce a valid ASCII slug".format(first_name, last_name))
    if source == "default":
        fail('slug "default" is reserved')
    return source


def normalize_role(value, row_number):
    role = clean(value).casefold()
    if role not in ROLE_VALUES:
        fail("row {} has unknown role {!r}".format(row_number, clean(value)))
    return ROLE_VALUES[role]


def normalize_headers(fieldnames):
    if not fieldnames:
        fail("CSV input has no header row")
    normalized = {}
    for field in fieldnames:
        key = clean(field).casefold()
        if key not in HEADER_ALIASES:
            continue
        canonical = HEADER_ALIASES[key]
        if canonical in normalized:
            fail("CSV contains duplicate header for {}".format(canonical))
        normalized[canonical] = field
    required = ("first_name", "last_name", "role")
    missing = [name for name in required if name not in normalized]
    if missing:
        fail("CSV is missing required header(s): {}".format(", ".join(missing)))
    return normalized


def render(input_path, output_path):
    try:
        with open(input_path, "r", encoding="utf-8-sig", newline="") as source:
            text = source.read()
    except (IOError, OSError) as exc:
        fail("could not read CSV: {}".format(exc))

    delimiter = choose_delimiter(text)
    reader = csv.DictReader(io.StringIO(text), delimiter=delimiter)
    headers = normalize_headers(reader.fieldnames)
    users = {}
    developer_slugs = []

    for row_number, row in enumerate(reader, 2):
        if None in row:
            fail("row {} has more fields than the header".format(row_number))
        if not any(clean(value) for value in row.values()):
            continue
        first_name = clean(row.get(headers["first_name"]))
        last_name = clean(row.get(headers["last_name"]))
        if not first_name or not last_name:
            fail("row {} requires non-empty first_name and last_name".format(row_number))
        role = normalize_role(row.get(headers["role"]), row_number)
        slug = make_slug(first_name, last_name)
        if slug in users:
            fail('duplicate derived slug "{}" (row {})'.format(slug, row_number))
        email = clean(row.get(headers["email"])) if "email" in headers else ""
        if not email:
            email = slug + "@example.invalid"
        elif not EMAIL_RE.match(email):
            fail("row {} has an invalid email".format(row_number))
        users[slug] = {
            "first_name": first_name,
            "last_name": last_name,
            "role": role,
            "email": email,
        }
        if role == "developer":
            developer_slugs.append(slug)

    lead_count = sum(1 for user in users.values() if user["role"] == "devops_lead")
    if lead_count != 1:
        fail("CSV must contain exactly one devops_lead (found {})".format(lead_count))
    if len(developer_slugs) < 2:
        fail("CSV must contain at least two developers (found {})".format(len(developer_slugs)))

    document = {"users": users, "developer_slugs": developer_slugs}
    output_directory = os.path.dirname(os.path.abspath(output_path))
    if not os.path.isdir(output_directory):
        fail("output directory does not exist: {}".format(output_directory))
    temporary_path = None
    try:
        descriptor, temporary_path = tempfile.mkstemp(prefix=".terraform-inputs-", dir=output_directory)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as destination:
            json.dump(document, destination, ensure_ascii=False, sort_keys=False, indent=2)
            destination.write("\n")
        os.replace(temporary_path, output_path)
        temporary_path = None
        os.chmod(output_path, 0o600)
    except (IOError, OSError, ValueError) as exc:
        fail("could not write rendered Terraform inputs: {}".format(exc))
    finally:
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_csv")
    parser.add_argument("output_json")
    arguments = parser.parse_args()
    try:
        render(arguments.input_csv, arguments.output_json)
    except ValueError as exc:
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
