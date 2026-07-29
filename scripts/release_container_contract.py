#!/usr/bin/python3
"""Structural allowlist for Gatebeam release containers."""

from __future__ import annotations

import argparse
import base64
import binascii
import gzip
import hashlib
import json
import os
import pathlib
import plistlib
import re
import stat
import sys
import unicodedata
import xml.etree.ElementTree as ET
import zipfile
from typing import BinaryIO

MAX_APP_BYTES = 512 * 1024 * 1024
MAX_EXPANDED_PKG_BYTES = 1024 * 1024 * 1024
MAX_CONTAINER_BYTES = 2 * 1024 * 1024 * 1024
MAX_APP_ENTRIES = 9
MAX_EXPANDED_PKG_ENTRIES = 32
XMLDSIG_NAMESPACE = "http://www.w3.org/2000/09/xmldsig#"

APP_LAYOUT = {
    ".": ("directory", 0o755),
    "Contents/": ("directory", 0o755),
    "Contents/Info.plist": ("file", 0o644),
    "Contents/MacOS/": ("directory", 0o755),
    "Contents/MacOS/Gatebeam": ("file", 0o755),
    "Contents/Resources/": ("directory", 0o755),
    "Contents/Resources/AppIcon.icns": ("file", 0o644),
    "Contents/_CodeSignature/": ("directory", 0o755),
    "Contents/_CodeSignature/CodeResources": ("file", 0o644),
}


class ContractError(ValueError):
    pass


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_absolute_directory(path: pathlib.Path) -> None:
    entry = path.lstat()
    if (
        not path.is_absolute()
        or stat.S_ISLNK(entry.st_mode)
        or not stat.S_ISDIR(entry.st_mode)
        or path.resolve(strict=True) != path.absolute()
    ):
        raise ContractError(f"unsafe directory: {path}")


def regular_file(
    path: pathlib.Path,
    maximum: int = 4 * 1024 * 1024 * 1024,
    *,
    reject_sparse: bool = False,
) -> os.stat_result:
    entry = path.lstat()
    if (
        stat.S_ISLNK(entry.st_mode)
        or not stat.S_ISREG(entry.st_mode)
        or entry.st_nlink != 1
        or entry.st_size <= 0
        or entry.st_size > maximum
    ):
        raise ContractError(f"unsafe regular file: {path}")
    if reject_sparse and entry.st_blocks * 512 < entry.st_size:
        raise ContractError(f"sparse container file is forbidden: {path}")
    return entry


def secure_digest_stream(
    path: pathlib.Path,
    maximum: int,
    expected_digest: str,
) -> tuple[BinaryIO, os.stat_result]:
    require_absolute_directory(path.parent)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    parent_descriptor = os.open(path.parent, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        descriptor = os.open(path.name, flags, dir_fd=parent_descriptor)
    finally:
        os.close(parent_descriptor)
    stream = os.fdopen(descriptor, "rb", closefd=True)
    try:
        before = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > maximum
            or before.st_blocks * 512 < before.st_size
        ):
            raise ContractError(f"unsafe regular file: {path}")
        digest = hashlib.sha256()
        remaining = before.st_size
        while remaining:
            chunk = stream.read(min(1024 * 1024, remaining))
            if not chunk:
                raise ContractError("application ZIP was truncated while hashing")
            digest.update(chunk)
            remaining -= len(chunk)
        if stream.read(1):
            raise ContractError("application ZIP grew while hashing")
        verify_stream_stable(stream, before)
        if digest.hexdigest() != expected_digest:
            raise ContractError("application ZIP digest changed before extraction")
        stream.seek(0)
        return stream, before
    except Exception:
        stream.close()
        raise


def verify_stream_stable(stream: BinaryIO, before: os.stat_result) -> None:
    after = os.fstat(stream.fileno())
    fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(after, field) for field in fields):
        raise ContractError("application ZIP changed while reading")


def namespace_key(path: str) -> str:
    normalized = unicodedata.normalize("NFC", path)
    if normalized != path:
        raise ContractError("tree contains a non-NFC path")
    return normalized.casefold()


def tree_records(
    root: pathlib.Path,
    *,
    maximum_entries: int = MAX_APP_ENTRIES,
    maximum_total: int = MAX_APP_BYTES,
) -> list[dict[str, object]]:
    require_absolute_directory(root)
    root_entry = root.lstat()
    records: list[dict[str, object]] = [
        {
            "path": ".",
            "mode": stat.S_IMODE(root_entry.st_mode),
            "type": "directory",
        }
    ]
    seen_inodes: set[tuple[int, int]] = set()
    seen_namespaces = {namespace_key(".")}
    total_size = 0
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        directory_path = pathlib.Path(directory)
        require_absolute_directory(directory_path)
        names.sort()
        files.sort()
        for name in names:
            child = directory_path / name
            entry = child.lstat()
            if stat.S_ISLNK(entry.st_mode) or not stat.S_ISDIR(entry.st_mode):
                raise ContractError("application contains a linked or special directory")
            relative = child.relative_to(root).as_posix() + "/"
            key = namespace_key(relative.rstrip("/"))
            if key in seen_namespaces:
                raise ContractError("tree contains a casefold or Unicode path collision")
            seen_namespaces.add(key)
            records.append(
                {
                    "path": relative,
                    "mode": stat.S_IMODE(entry.st_mode),
                    "type": "directory",
                }
            )
        for name in files:
            child = directory_path / name
            entry = regular_file(child)
            inode = (entry.st_dev, entry.st_ino)
            if inode in seen_inodes:
                raise ContractError("application contains a hard-linked file")
            seen_inodes.add(inode)
            relative = child.relative_to(root).as_posix()
            key = namespace_key(relative)
            if key in seen_namespaces:
                raise ContractError("tree contains a casefold or Unicode path collision")
            seen_namespaces.add(key)
            total_size += entry.st_size
            if total_size > maximum_total:
                raise ContractError("tree exceeds its expanded byte budget")
            digest = hashlib.sha256()
            with child.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            records.append(
                {
                    "path": child.relative_to(root).as_posix(),
                    "mode": stat.S_IMODE(entry.st_mode),
                    "size": entry.st_size,
                    "sha256": digest.hexdigest(),
                    "type": "file",
                }
            )
            if len(records) > maximum_entries:
                raise ContractError("tree exceeds its entry-count budget")
        if len(records) > maximum_entries:
            raise ContractError("tree exceeds its entry-count budget")
    return records


def validate_app_layout(
    root: pathlib.Path,
    identifier: str,
    version: str,
    build: str,
) -> list[dict[str, object]]:
    records = tree_records(root)
    actual = {
        record["path"]: (record["type"], record["mode"])
        for record in records
    }
    if actual != APP_LAYOUT:
        raise ContractError(
            "application tree does not match the Gatebeam allowlist: "
            f"{json.dumps(actual, sort_keys=True)}"
        )
    executable_paths = {
        record["path"]
        for record in records
        if record["type"] == "file" and int(record["mode"]) & 0o111
    }
    if executable_paths != {"Contents/MacOS/Gatebeam"}:
        raise ContractError("application executable or nested-code set is invalid")
    limits = {
        "Contents/Info.plist": 1024 * 1024,
        "Contents/MacOS/Gatebeam": 256 * 1024 * 1024,
        "Contents/Resources/AppIcon.icns": 16 * 1024 * 1024,
        "Contents/_CodeSignature/CodeResources": 16 * 1024 * 1024,
    }
    record_map = {str(record["path"]): record for record in records}
    for path, maximum in limits.items():
        size = record_map[path].get("size")
        if not isinstance(size, int) or size <= 0 or size > maximum:
            raise ContractError(f"application file size is invalid: {path}")
    try:
        with (root / "Contents/Info.plist").open("rb") as stream:
            metadata = plistlib.load(stream)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise ContractError("application Info.plist is invalid") from error
    if (
        not isinstance(metadata, dict)
        or metadata.get("CFBundleIdentifier") != identifier
        or metadata.get("CFBundleExecutable") != "Gatebeam"
        or metadata.get("CFBundleShortVersionString") != version
        or str(metadata.get("CFBundleVersion", "")) != build
    ):
        raise ContractError("application Info.plist identity is invalid")
    return records


def tree_digest(
    root: pathlib.Path,
    identifier: str,
    version: str,
    build: str,
) -> str:
    payload = json.dumps(
        validate_app_layout(root, identifier, version, build),
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def write_exclusive(path: pathlib.Path, value: str) -> None:
    require_absolute_directory(path.parent)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        os.write(descriptor, (value + "\n").encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def validate_zip_member(info: zipfile.ZipInfo) -> tuple[pathlib.PurePosixPath, bool, int]:
    name = info.filename
    if (
        not name
        or "\x00" in name
        or "\\" in name
        or name.startswith("/")
        or re.match(r"^[A-Za-z]:", name)
        or unicodedata.normalize("NFC", name) != name
    ):
        raise ContractError("application ZIP contains an unsafe path")
    relative = pathlib.PurePosixPath(name)
    if any(part in ("", ".", "..") for part in relative.parts):
        raise ContractError("application ZIP contains normalized path traversal")
    if relative.parts[0] != "Gatebeam.app":
        raise ContractError("application ZIP root must contain only Gatebeam.app")
    mode = (info.external_attr >> 16) & 0xFFFF
    is_directory = info.is_dir()
    if mode:
        expected = stat.S_IFDIR if is_directory else stat.S_IFREG
        if stat.S_IFMT(mode) not in (0, expected):
            raise ContractError("application ZIP contains a link or special entry")
    if info.flag_bits & 0x1:
        raise ContractError("application ZIP contains an encrypted entry")
    permissions = stat.S_IMODE(mode) if mode else (0o755 if is_directory else 0o644)
    if permissions & 0o7000 or permissions & 0o002:
        raise ContractError("application ZIP contains unsafe permissions")
    return relative, is_directory, permissions


def extract_app_zip(arguments: argparse.Namespace) -> None:
    archive = pathlib.Path(arguments.archive).absolute()
    output = pathlib.Path(arguments.output).absolute()
    stream, before = secure_digest_stream(
        archive,
        MAX_CONTAINER_BYTES,
        arguments.expected_digest,
    )
    if output.exists() or output.is_symlink():
        stream.close()
        raise ContractError("ZIP extraction destination already exists")
    output.mkdir(mode=0o700)
    seen: set[str] = set()
    total = 0
    try:
        with stream, zipfile.ZipFile(stream, "r") as bundle:
            infos = bundle.infolist()
            if not infos or len(infos) > 20000:
                raise ContractError("application ZIP entry count is invalid")
            for info in infos:
                relative, is_directory, permissions = validate_zip_member(info)
                canonical = namespace_key(relative.as_posix().rstrip("/"))
                if canonical in seen:
                    raise ContractError(
                        "application ZIP contains duplicate or normalized-colliding paths"
                    )
                seen.add(canonical)
                total += info.file_size
                if info.file_size > arguments.maximum_total or total > arguments.maximum_total:
                    raise ContractError("application ZIP exceeds the extraction limit")
                destination = output.joinpath(*relative.parts)
                if is_directory:
                    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
                    os.chmod(destination, permissions)
                    continue
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
                descriptor = os.open(destination, flags, permissions)
                try:
                    with bundle.open(info, "r") as source:
                        remaining = info.file_size
                        while remaining:
                            chunk = source.read(min(1024 * 1024, remaining))
                            if not chunk:
                                raise ContractError("application ZIP member was truncated")
                            os.write(descriptor, chunk)
                            remaining -= len(chunk)
                        if source.read(1):
                            raise ContractError("application ZIP member exceeded metadata")
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
                os.chmod(destination, permissions)
            verify_stream_stable(stream, before)
    except (OSError, zipfile.BadZipFile) as error:
        raise ContractError("application ZIP extraction failed") from error
    app = output / "Gatebeam.app"
    if set(output.iterdir()) != {app}:
        raise ContractError("application ZIP extracted unexpected root entries")
    tree_records(app)


def parse_xml(path: pathlib.Path) -> ET.Element:
    entry = regular_file(path, 1024 * 1024)
    payload = path.read_bytes()
    if (
        len(payload) != entry.st_size
        or b"<!DOCTYPE" in payload
        or b"<!ENTITY" in payload
        or b"<!--" in payload
        or payload.count(b"<?") > 1
    ):
        raise ContractError("unsafe package XML")
    try:
        return ET.fromstring(payload)
    except ET.ParseError as error:
        raise ContractError("invalid package XML") from error


def component_root(expanded: pathlib.Path) -> pathlib.Path:
    entries = set(expanded.iterdir())
    distribution_path = expanded / "Distribution"
    if distribution_path in entries:
        raise ContractError("Distribution packages are forbidden")
    expected = {
        expanded / "Bom",
        expanded / "PackageInfo",
        expanded / "Payload",
        expanded / "Scripts",
    }
    if entries != expected:
        raise ContractError("flat PKG contains extra or missing component entries")
    return expanded


def require_element(
    element: ET.Element,
    tag: str,
    attributes: dict[str, str],
    children: int,
) -> None:
    if (
        element.tag != tag
        or element.attrib != attributes
        or len(element) != children
        or (element.text or "").strip()
        or (element.tail or "").strip()
    ):
        raise ContractError(f"PackageInfo element is outside the allowlist: {tag}")


def validate_package_info(
    path: pathlib.Path,
    identifier: str,
    version: str,
    build: str,
    payload_records: list[dict[str, object]],
) -> None:
    root = parse_xml(path)
    required_root = {
        "overwrite-permissions": "true",
        "relocatable": "false",
        "identifier": identifier,
        "postinstall-action": "none",
        "version": version,
        "format-version": "2",
        "install-location": "/Applications",
        "auth": "root",
    }
    if (
        root.tag != "pkg-info"
        or any(name not in set(required_root) | {"generator-version"} for name in root.attrib)
        or any(root.attrib.get(name) != value for name, value in required_root.items())
        or not re.fullmatch(r"[ -~]{1,128}", root.attrib.get("generator-version", ""))
        or (root.text or "").strip()
        or (root.tail or "").strip()
    ):
        raise ContractError("PackageInfo root metadata is invalid")
    children = list(root)
    expected_tags = [
        "payload",
        "bundle",
        "bundle-version",
        "upgrade-bundle",
        "update-bundle",
        "atomic-update-bundle",
        "strict-identifier",
        "relocate",
        "scripts",
    ]
    if [child.tag for child in children] != expected_tags:
        raise ContractError("PackageInfo child element allowlist is invalid")
    total_bytes = sum(
        int(record.get("size", 0))
        for record in payload_records
        if record["type"] == "file"
    )
    payload_files = str(len(payload_records))
    install_kbytes = children[0].attrib.get("installKBytes", "")
    if (
        children[0].attrib.get("numberOfFiles") != payload_files
        or not install_kbytes.isdecimal()
        or int(install_kbytes) < (total_bytes + 1023) // 1024
        or int(install_kbytes) > (total_bytes + 1023) // 1024 + 16
        or len(children[0]) != 0
        or (children[0].text or "").strip()
    ):
        raise ContractError("PackageInfo payload accounting is invalid")
    bundle_attrs = {
        "path": "./Gatebeam.app",
        "id": identifier,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
    }
    require_element(children[1], "bundle", bundle_attrs, 0)
    for index, tag in ((2, "bundle-version"), (3, "upgrade-bundle")):
        require_element(children[index], tag, {}, 1)
        require_element(children[index][0], "bundle", {"id": identifier}, 0)
    require_element(children[4], "update-bundle", {}, 0)
    require_element(children[5], "atomic-update-bundle", {}, 0)
    for index, tag in ((6, "strict-identifier"), (7, "relocate")):
        require_element(children[index], tag, {}, 1)
        require_element(children[index][0], "bundle", {"id": identifier}, 0)
    require_element(children[8], "scripts", {}, 1)
    require_element(
        children[8][0],
        "postinstall",
        {"file": "./postinstall", "timeout": "600"},
        0,
    )


def validate_xar_toc(arguments: argparse.Namespace) -> None:
    root = parse_xml(pathlib.Path(arguments.toc).absolute())
    if (
        root.tag != "xar"
        or root.attrib
        or len(root) != 1
        or root[0].tag != "toc"
        or root[0].attrib
    ):
        raise ContractError("XAR TOC root is invalid")
    toc_children = list(root[0])
    files = [entry for entry in toc_children if entry.tag == "file"]
    signatures = [entry for entry in toc_children if entry.tag == "signature"]
    timestamp_signatures = [
        entry for entry in toc_children if entry.tag == "x-signature"
    ]
    if (
        len(files) != 4
        or len(signatures) != 1
        or len(timestamp_signatures) > 1
        or len(toc_children) != 7 + len(timestamp_signatures)
        or [entry.tag for entry in toc_children[:3]]
        != ["checksum", "creation-time", "signature"]
        or (
            timestamp_signatures
            and toc_children[3].tag != "x-signature"
        )
        or any(
            entry.tag != "file"
            for entry in toc_children[4 if timestamp_signatures else 3 :]
        )
        or any(
            entry.tag
            not in {
                "checksum",
                "creation-time",
                "signature",
                "x-signature",
                "file",
            }
            for entry in toc_children
        )
    ):
        raise ContractError("flat PKG XAR must contain exactly four file records")

    checksum = toc_children[0]
    checksum_children = list(checksum)
    if (
        checksum.attrib != {"style": "sha1"}
        or [child.tag for child in checksum_children] != ["size", "offset"]
        or any(child.attrib or len(child) for child in checksum_children)
        or checksum_children[0].text != "20"
        or checksum_children[1].text != "0"
    ):
        raise ContractError("XAR TOC checksum contract is invalid")
    creation_time = toc_children[1]
    if (
        creation_time.attrib
        or len(creation_time)
        or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T"
            r"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]{1,9})?Z?",
            creation_time.text or "",
        )
    ):
        raise ContractError("XAR creation time is invalid")

    def signature_contract(
        element: ET.Element,
        tag: str,
        style: str,
        expected_offset: int,
    ) -> tuple[int, tuple[str, ...]]:
        children = list(element)
        key_info_tag = f"{{{XMLDSIG_NAMESPACE}}}KeyInfo"
        if (
            element.tag != tag
            or element.attrib != {"style": style}
            or [child.tag for child in children] != ["offset", "size", key_info_tag]
            or any(children[index].attrib or len(children[index]) for index in (0, 1))
        ):
            raise ContractError(f"XAR {tag} metadata is outside the allowlist")
        offset_text = children[0].text or ""
        size_text = children[1].text or ""
        if (
            not offset_text.isdecimal()
            or not size_text.isdecimal()
            or int(offset_text) != expected_offset
        ):
            raise ContractError(f"XAR {tag} range is invalid")
        size = int(size_text)
        if (
            (tag == "signature" and not 128 <= size <= 4096)
            or (tag == "x-signature" and not 256 <= size <= 1024 * 1024)
        ):
            raise ContractError(f"XAR {tag} size is invalid")
        key_info = children[2]
        x509_tag = f"{{{XMLDSIG_NAMESPACE}}}X509Data"
        certificate_tag = f"{{{XMLDSIG_NAMESPACE}}}X509Certificate"
        if key_info.attrib or len(key_info) != 1 or key_info[0].tag != x509_tag:
            raise ContractError(f"XAR {tag} certificate container is invalid")
        x509_data = key_info[0]
        certificates = list(x509_data)
        if (
            x509_data.attrib
            or not 1 <= len(certificates) <= 8
            or any(
                certificate.tag != certificate_tag
                or certificate.attrib
                or len(certificate)
                for certificate in certificates
            )
        ):
            raise ContractError(f"XAR {tag} certificate chain is invalid")
        encoded_chain: list[str] = []
        for certificate in certificates:
            encoded = "".join((certificate.text or "").split())
            try:
                decoded = base64.b64decode(encoded, validate=True)
            except (binascii.Error, ValueError) as error:
                raise ContractError(
                    f"XAR {tag} certificate encoding is invalid"
                ) from error
            if len(decoded) < 5 or len(decoded) > 64 * 1024 or decoded[0] != 0x30:
                raise ContractError(f"XAR {tag} certificate DER is invalid")
            encoded_chain.append(encoded)
        return size, tuple(encoded_chain)

    signature_size, certificate_chain = signature_contract(
        signatures[0],
        "signature",
        "RSA",
        20,
    )
    signed_heap_start = 20 + signature_size
    if timestamp_signatures:
        timestamp_size, timestamp_chain = signature_contract(
            timestamp_signatures[0],
            "x-signature",
            "CMS",
            signed_heap_start,
        )
        if timestamp_chain != certificate_chain:
            raise ContractError("XAR timestamp certificate chain does not match signature")
        signed_heap_start += timestamp_size

    names: set[str] = set()
    identifiers: set[str] = set()
    total = 0
    archived_ranges: list[tuple[int, int]] = []
    for entry in files:
        children = {child.tag: child for child in entry}
        child_tags = set(children)
        minimal_tags = {"name", "type", "mode", "data"}
        full_tags = minimal_tags | {"uid", "gid", "inode"}
        if (
            set(entry.attrib) != {"id"}
            or not str(entry.attrib.get("id", "")).isdecimal()
            or entry.attrib["id"] in identifiers
            or
            len(children) != len(entry)
            or
            child_tags not in (minimal_tags, full_tags)
            or children["type"].text != "file"
            or children["mode"].text not in {"0644", "0664"}
            or len(children["data"]) == 0
            or children["data"].attrib
            or any(
                children[tag].attrib or len(children[tag])
                for tag in ("name", "type", "mode")
            )
        ):
            raise ContractError("XAR file record is outside the allowlist")
        if child_tags == full_tags and any(
            children[tag].attrib
            or len(children[tag])
            or children[tag].text != "0"
            for tag in ("uid", "gid", "inode")
        ):
            raise ContractError("XAR ownership metadata is invalid")
        identifiers.add(entry.attrib["id"])
        name = children["name"].text or ""
        key = namespace_key(name)
        if key in names:
            raise ContractError("XAR contains duplicate or normalized-colliding names")
        names.add(key)
        data_element = children["data"]
        data = {child.tag: child for child in data_element}
        if len(data) != len(data_element) or set(data) != {
            "archived-checksum",
            "extracted-checksum",
            "encoding",
            "size",
            "offset",
            "length",
        }:
            raise ContractError("XAR data metadata is outside the allowlist")
        for checksum_name in ("archived-checksum", "extracted-checksum"):
            member_checksum = data[checksum_name]
            if (
                member_checksum.attrib != {"style": "sha1"}
                or len(member_checksum)
                or not re.fullmatch(r"[0-9a-f]{40}", member_checksum.text or "")
            ):
                raise ContractError("XAR member checksum is invalid")
        encoding = data["encoding"]
        if (
            set(encoding.attrib) != {"style"}
            or encoding.attrib["style"]
            not in {"application/octet-stream", "application/x-gzip"}
            or len(encoding)
        ):
            raise ContractError("XAR member encoding is invalid")
        size_text = data.get("size").text if data.get("size") is not None else ""
        offset_text = data.get("offset").text if data.get("offset") is not None else ""
        length_text = data.get("length").text if data.get("length") is not None else ""
        if (
            not str(size_text).isdecimal()
            or not str(offset_text).isdecimal()
            or not str(length_text).isdecimal()
            or int(str(size_text)) <= 0
            or int(str(offset_text)) < signed_heap_start
            or int(str(length_text)) <= 0
            or int(str(size_text)) > MAX_CONTAINER_BYTES
            or int(str(length_text)) > MAX_CONTAINER_BYTES
            or int(str(offset_text)) + int(str(length_text)) > MAX_CONTAINER_BYTES
        ):
            raise ContractError("XAR member size is invalid")
        total += int(str(size_text))
        archived_ranges.append(
            (
                int(str(offset_text)),
                int(str(offset_text)) + int(str(length_text)),
            )
        )
    expected = {namespace_key(name) for name in ("Bom", "Payload", "Scripts", "PackageInfo")}
    ordered_ranges = sorted(archived_ranges)
    if (
        names != expected
        or total > MAX_CONTAINER_BYTES
        or any(
            current[0] < previous[1]
            for previous, current in zip(ordered_ranges, ordered_ranges[1:])
        )
    ):
        raise ContractError("flat PKG XAR root or byte budget is invalid")


def read_exact(stream: gzip.GzipFile, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = stream.read(min(1024 * 1024, remaining))
        if not chunk:
            raise ContractError("cpio stream is truncated")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def parse_odc_cpio(
    path: pathlib.Path,
    maximum_entries: int,
    maximum_total: int,
) -> list[dict[str, object]]:
    regular_file(path, MAX_CONTAINER_BYTES, reject_sparse=True)
    records: list[dict[str, object]] = []
    seen: set[str] = set()
    total = 0
    try:
        with gzip.open(path, "rb") as stream:
            while True:
                header = read_exact(stream, 76)
                if header[:6] != b"070707":
                    raise ContractError("package archive is not strict odc cpio")
                widths = (6, 6, 6, 6, 6, 6, 6, 11, 6, 11)
                values: list[int] = []
                offset = 6
                for width in widths:
                    field = header[offset : offset + width]
                    offset += width
                    if not field or any(byte not in b"01234567" for byte in field):
                        raise ContractError("cpio header contains a non-octal field")
                    values.append(int(field, 8))
                (
                    _device,
                    _inode,
                    mode,
                    uid,
                    gid,
                    links,
                    _rdevice,
                    _mtime,
                    name_size,
                    file_size,
                ) = values
                if name_size <= 1 or name_size > 4096:
                    raise ContractError("cpio path length is invalid")
                raw_name = read_exact(stream, name_size)
                if raw_name[-1:] != b"\0" or b"\0" in raw_name[:-1]:
                    raise ContractError("cpio path is not canonically terminated")
                try:
                    name = raw_name[:-1].decode("utf-8")
                except UnicodeDecodeError as error:
                    raise ContractError("cpio path is not UTF-8") from error
                if name == "TRAILER!!!":
                    if file_size != 0:
                        raise ContractError("cpio trailer contains data")
                    trailing = stream.read(513)
                    if len(trailing) > 512 or any(trailing):
                        raise ContractError("cpio contains trailing nonzero data")
                    break
                relative = pathlib.PurePosixPath(name)
                if (
                    not name
                    or name.startswith("/")
                    or "\\" in name
                    or any(part in ("", "..") for part in relative.parts)
                ):
                    raise ContractError("cpio contains an unsafe path")
                normalized = relative.as_posix().removeprefix("./")
                normalized = normalized or "."
                key = namespace_key(normalized)
                if key in seen:
                    raise ContractError("cpio contains duplicate or normalized-colliding paths")
                seen.add(key)
                kind_bits = stat.S_IFMT(mode)
                if kind_bits == stat.S_IFDIR:
                    kind = "directory"
                    if file_size != 0:
                        raise ContractError("cpio directory contains data")
                elif kind_bits == stat.S_IFREG:
                    kind = "file"
                    if links != 1:
                        raise ContractError("cpio contains a hard-linked file")
                else:
                    raise ContractError("cpio contains a link or special entry")
                if uid != 0 or gid != 0 or stat.S_IMODE(mode) & 0o7000:
                    raise ContractError("cpio ownership or permissions are unsafe")
                total += file_size
                if total > maximum_total or file_size > maximum_total:
                    raise ContractError("cpio exceeds its expanded byte budget")
                records.append(
                    {
                        "path": normalized,
                        "type": kind,
                        "mode": stat.S_IMODE(mode),
                        "size": file_size,
                    }
                )
                if len(records) > maximum_entries:
                    raise ContractError("cpio exceeds its entry-count budget")
                remaining = file_size
                while remaining:
                    chunk = stream.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ContractError("cpio file data is truncated")
                    remaining -= len(chunk)
    except (OSError, EOFError, gzip.BadGzipFile) as error:
        raise ContractError("package cpio preflight failed") from error
    return records


def validate_raw_pkg(arguments: argparse.Namespace) -> None:
    root = pathlib.Path(arguments.root).absolute()
    require_absolute_directory(root)
    expected = {root / name for name in ("Bom", "Payload", "Scripts", "PackageInfo")}
    if set(root.iterdir()) != expected:
        raise ContractError("raw flat PKG root is outside the allowlist")
    for name in ("Bom", "PackageInfo"):
        regular_file(root / name, 128 * 1024 * 1024, reject_sparse=True)
    payload = parse_odc_cpio(root / "Payload", MAX_APP_ENTRIES + 1, MAX_APP_BYTES)
    expected_payload = {
        ".": ("directory", 0o755),
        **{
            (
                "Gatebeam.app"
                if path == "."
                else f"Gatebeam.app/{path.rstrip('/')}"
            ): value
            for path, value in APP_LAYOUT.items()
        },
    }
    actual_payload = {
        str(record["path"]): (record["type"], record["mode"])
        for record in payload
    }
    if actual_payload != expected_payload:
        raise ContractError("raw PKG payload cpio does not match the app allowlist")
    scripts = parse_odc_cpio(root / "Scripts", 3, 2 * 1024 * 1024)
    expected_scripts = {
        ".": ("directory", 0o755),
        "postinstall": ("file", 0o755),
        "migrate_legacy_install.sh": ("file", 0o755),
    }
    actual_scripts = {
        str(record["path"]): (record["type"], record["mode"])
        for record in scripts
    }
    if actual_scripts != expected_scripts:
        raise ContractError("raw PKG scripts cpio is outside the allowlist")


def validate_pkg(arguments: argparse.Namespace) -> None:
    expanded = pathlib.Path(arguments.root).absolute()
    scripts_source = pathlib.Path(arguments.scripts_root).absolute()
    bom_list = pathlib.Path(arguments.bom_list).absolute()
    require_absolute_directory(expanded)
    require_absolute_directory(scripts_source)
    tree_records(
        expanded,
        maximum_entries=MAX_EXPANDED_PKG_ENTRIES,
        maximum_total=MAX_EXPANDED_PKG_BYTES,
    )
    component = component_root(expanded)
    expected_entries = {
        component / "Bom",
        component / "PackageInfo",
        component / "Payload",
        component / "Scripts",
    }
    if set(component.iterdir()) != expected_entries:
        raise ContractError("PKG component contains extra or missing entries")
    regular_file(component / "Bom", 128 * 1024 * 1024)
    payload = component / "Payload"
    require_absolute_directory(payload)
    app = payload / "Gatebeam.app"
    if set(payload.iterdir()) != {app}:
        raise ContractError("PKG payload must contain only Gatebeam.app")
    payload_records = validate_app_layout(
        app,
        arguments.identifier,
        arguments.version,
        arguments.build,
    )
    validate_package_info(
        component / "PackageInfo",
        arguments.identifier,
        arguments.version,
        arguments.build,
        payload_records,
    )
    expected_bom = {"Gatebeam.app"}
    expected_bom.update(
        f"Gatebeam.app/{record['path'].rstrip('/')}"
        for record in payload_records
        if record["path"] != "."
    )
    actual_bom: set[str] = set()
    regular_file(bom_list, 128 * 1024 * 1024)
    for raw_line in bom_list.read_text(encoding="utf-8").splitlines():
        line = raw_line.removeprefix("./").rstrip("/")
        if not line or line == "." or line in actual_bom or ".." in pathlib.PurePosixPath(line).parts:
            if line in actual_bom:
                raise ContractError("BOM contains duplicate paths")
            continue
        actual_bom.add(line)
    if actual_bom != expected_bom:
        raise ContractError("BOM and expanded payload trees do not have an exact closure")

    scripts = component / "Scripts"
    require_absolute_directory(scripts)
    expected_scripts = {
        "postinstall": scripts_source / "postinstall",
        "migrate_legacy_install.sh": scripts_source / "migrate_legacy_install.sh",
    }
    if {path.name for path in scripts.iterdir()} != set(expected_scripts):
        raise ContractError("PKG Scripts contains an unexpected path")
    for name, source in expected_scripts.items():
        destination = scripts / name
        regular_file(source, 1024 * 1024)
        regular_file(destination, 1024 * 1024)
        if source.read_bytes() != destination.read_bytes():
            raise ContractError(f"PKG script does not match tagged source: {name}")
    write_exclusive(pathlib.Path(arguments.output_app).absolute(), os.fspath(app))
    write_exclusive(
        pathlib.Path(arguments.output_digest).absolute(),
        tree_digest(app, arguments.identifier, arguments.version, arguments.build),
    )


def validate_expanded_pkg_root(arguments: argparse.Namespace) -> None:
    expanded = pathlib.Path(arguments.root).absolute()
    tree_records(
        expanded,
        maximum_entries=MAX_EXPANDED_PKG_ENTRIES,
        maximum_total=MAX_EXPANDED_PKG_BYTES,
    )
    component_root(expanded)


def validate_dmg(arguments: argparse.Namespace) -> None:
    root = pathlib.Path(arguments.root).absolute()
    require_absolute_directory(root)
    app = root / "Gatebeam.app"
    applications = root / "Applications"
    if set(root.iterdir()) != {app, applications}:
        raise ContractError("DMG root contains an unexpected entry")
    link = applications.lstat()
    if not stat.S_ISLNK(link.st_mode) or os.readlink(applications) != "/Applications":
        raise ContractError("DMG Applications shortcut is invalid")
    validate_app_layout(app, arguments.identifier, arguments.version, arguments.build)
    write_exclusive(pathlib.Path(arguments.output_app).absolute(), os.fspath(app))
    write_exclusive(
        pathlib.Path(arguments.output_digest).absolute(),
        tree_digest(app, arguments.identifier, arguments.version, arguments.build),
    )


def validate_app(arguments: argparse.Namespace) -> None:
    digest = tree_digest(
        pathlib.Path(arguments.root).absolute(),
        arguments.identifier,
        arguments.version,
        arguments.build,
    )
    write_exclusive(pathlib.Path(arguments.output_digest).absolute(), digest)


def validate_container_file(arguments: argparse.Namespace) -> None:
    maximum = MAX_CONTAINER_BYTES
    regular_file(pathlib.Path(arguments.path).absolute(), maximum, reject_sparse=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    extract = subparsers.add_parser("extract-app-zip")
    extract.add_argument("--archive", required=True)
    extract.add_argument("--output", required=True)
    extract.add_argument("--maximum-total", required=True, type=int)
    extract.add_argument("--expected-digest", required=True)

    app = subparsers.add_parser("validate-app")
    app.add_argument("--root", required=True)
    app.add_argument("--identifier", required=True)
    app.add_argument("--version", required=True)
    app.add_argument("--build", required=True)
    app.add_argument("--output-digest", required=True)

    container = subparsers.add_parser("validate-container-file")
    container.add_argument("--path", required=True)

    toc = subparsers.add_parser("validate-pkg-toc")
    toc.add_argument("--toc", required=True)

    expanded = subparsers.add_parser("validate-expanded-pkg-root")
    expanded.add_argument("--root", required=True)

    raw_package = subparsers.add_parser("validate-raw-pkg")
    raw_package.add_argument("--root", required=True)

    package = subparsers.add_parser("validate-pkg")
    package.add_argument("--root", required=True)
    package.add_argument("--identifier", required=True)
    package.add_argument("--version", required=True)
    package.add_argument("--build", required=True)
    package.add_argument("--scripts-root", required=True)
    package.add_argument("--bom-list", required=True)
    package.add_argument("--output-app", required=True)
    package.add_argument("--output-digest", required=True)

    dmg = subparsers.add_parser("validate-dmg")
    dmg.add_argument("--root", required=True)
    dmg.add_argument("--identifier", required=True)
    dmg.add_argument("--version", required=True)
    dmg.add_argument("--build", required=True)
    dmg.add_argument("--output-app", required=True)
    dmg.add_argument("--output-digest", required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "extract-app-zip":
            if arguments.maximum_total <= 0 or arguments.maximum_total > 4 * 1024 * 1024 * 1024:
                raise ContractError("ZIP extraction limit is invalid")
            if not re.fullmatch(r"[0-9a-f]{64}", arguments.expected_digest):
                raise ContractError("ZIP expected digest is invalid")
            extract_app_zip(arguments)
        elif arguments.command == "validate-app":
            validate_app(arguments)
        elif arguments.command == "validate-container-file":
            validate_container_file(arguments)
        elif arguments.command == "validate-pkg-toc":
            validate_xar_toc(arguments)
        elif arguments.command == "validate-expanded-pkg-root":
            validate_expanded_pkg_root(arguments)
        elif arguments.command == "validate-raw-pkg":
            validate_raw_pkg(arguments)
        elif arguments.command == "validate-pkg":
            validate_pkg(arguments)
        elif arguments.command == "validate-dmg":
            validate_dmg(arguments)
    except (ContractError, OSError, UnicodeError) as error:
        fail(str(error))


if __name__ == "__main__":
    main()
