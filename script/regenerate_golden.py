#!/usr/bin/env python3
"""Regenerate golden DICOM SEG fixtures using highdicom as the oracle.

Usage:
    python3 script/regenerate_golden.py

For each scenario, this writes three artifacts under spec/golden/:
    <scenario>.dcm                — the highdicom-produced SEG file
    <scenario>.elements.yaml      — every top-level Data Element ({tag, vr, value})
                                    with PixelData replaced by {sha256: "..."}
    <scenario>.pixel_data.bin     — the raw packed-bits PixelData bytes

All UIDs and timestamps are deterministic constants so that output is byte-stable.

Reference series:
    /Users/jonathan/Projects/dicom-imager/spec/fixtures/files/CT_small.dcm  (one slice)

For the multi-slice scenario we synthesize additional slices by copying CT_small.dcm
and mutating ImagePositionPatient (bumped along z) and SOPInstanceUID. These synthesized
source slices are written to spec/fixtures/ct_small_series/ so the Ruby specs can read
the exact same reference series.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import sys
from pathlib import Path

import numpy as np
import pydicom
import yaml
from pydicom.dataset import Dataset
from pydicom.uid import ExplicitVRLittleEndian

import highdicom as hd
from highdicom.seg import (
    SegmentDescription,
    SegmentationTypeValues,
    SegmentAlgorithmTypeValues,
    Segmentation,
)
from highdicom.sr.coding import CodedConcept


HERE          = Path(__file__).resolve().parent
GEM_ROOT      = HERE.parent
GOLDEN_DIR    = GEM_ROOT / "spec" / "golden"
FIXTURES_DIR  = GEM_ROOT / "spec" / "fixtures"
SOURCE_CT     = Path("/Users/jonathan/Projects/dicom-imager/spec/fixtures/files/CT_small.dcm")

# Deterministic UIDs and content metadata so output is byte-stable.
SERIES_UID            = "1.2.826.0.1.3680043.10.511.3.123.4567.1"
INSTANCE_UID          = "1.2.826.0.1.3680043.10.511.3.123.4567.2"
FRAME_OF_REFERENCE    = "1.3.6.1.4.1.5962.1.4.1.1.20040119072730.12322"  # matches CT_small
CONTENT_CREATOR_NAME  = "Doe^Jane"
CONTENT_LABEL         = "BONE_SEG"
CONTENT_DESCRIPTION   = "Phase 1 fixture"
SERIES_NUMBER         = 1001
INSTANCE_NUMBER       = 1
CONTENT_DATE          = "20260101"
CONTENT_TIME          = "120000.000000"
DIMENSION_ORG_UID     = "1.2.826.0.1.3680043.10.511.3.123.4567.10"

# Synthesized multi-slice series UIDs (used when we copy CT_small.dcm into per-slice files).
SYNTH_SERIES_UID      = "1.2.826.0.1.3680043.10.511.3.123.4567.100"
SYNTH_STUDY_UID       = "1.2.826.0.1.3680043.10.511.3.123.4567.101"
SYNTH_SOP_INSTANCE_PREFIX = "1.2.826.0.1.3680043.10.511.3.123.4567.200"
SYNTH_SLICE_THICKNESS = 5.0  # mm — matches CT_small

# Multi-slice series UIDs for SEG itself
MULTI_SERIES_UID      = "1.2.826.0.1.3680043.10.511.3.123.4567.300"
MULTI_INSTANCE_UID    = "1.2.826.0.1.3680043.10.511.3.123.4567.301"


def _synthesize_multi_slice_series(num_slices: int = 4) -> list[Path]:
    """Copy CT_small.dcm into num_slices files with bumped position + SOPInstanceUID.

    All slices share the same SeriesInstanceUID + StudyInstanceUID + FrameOfReferenceUID
    so highdicom treats them as a coherent reference series.
    """
    out_dir = FIXTURES_DIR / "ct_small_series"
    out_dir.mkdir(parents=True, exist_ok=True)
    # Clear any stale slice files (preserve nothing).
    for old in out_dir.glob("*.dcm"):
        old.unlink()

    base = pydicom.dcmread(str(SOURCE_CT))
    base_pos = list(map(float, base.ImagePositionPatient))

    paths: list[Path] = []
    for k in range(num_slices):
        ds = pydicom.dcmread(str(SOURCE_CT))
        # Bump z position by k * slice_thickness.
        ds.ImagePositionPatient = [
            base_pos[0],
            base_pos[1],
            base_pos[2] + k * SYNTH_SLICE_THICKNESS,
        ]
        ds.SliceLocation = base_pos[2] + k * SYNTH_SLICE_THICKNESS
        ds.SOPInstanceUID         = f"{SYNTH_SOP_INSTANCE_PREFIX}.{k + 1}"
        ds.SeriesInstanceUID      = SYNTH_SERIES_UID
        ds.StudyInstanceUID       = SYNTH_STUDY_UID
        ds.InstanceNumber         = k + 1
        ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
        path = out_dir / f"slice_{k + 1:03d}.dcm"
        ds.save_as(str(path))
        paths.append(path)
    return paths


def _build_segment(label: str,
                   category_code: tuple[str, str, str],
                   type_code:    tuple[str, str, str],
                   algorithm_name: str,
                   algorithm_version: str,
                   algorithm_type: str = "MANUAL") -> SegmentDescription:
    """Construct a single SegmentDescription matching the Ruby API shape."""
    category = CodedConcept(value=category_code[0], scheme_designator=category_code[1], meaning=category_code[2])
    seg_type = CodedConcept(value=type_code[0],     scheme_designator=type_code[1],     meaning=type_code[2])
    algo_type = SegmentAlgorithmTypeValues(algorithm_type)

    kwargs = dict(
        segment_number               = 1,
        segment_label                = label,
        segmented_property_category   = category,
        segmented_property_type       = seg_type,
        algorithm_type                = algo_type,
    )
    if algo_type != SegmentAlgorithmTypeValues.MANUAL:
        kwargs.update(
            algorithm_identification = hd.AlgorithmIdentificationSequence(
                name    = algorithm_name,
                version = algorithm_version,
                family  = CodedConcept(value="113076", scheme_designator="DCM", meaning="Segmentation"),
            ),
        )
    return SegmentDescription(**kwargs)


def _build_seg(reference_paths: list[Path],
               mask: np.ndarray,
               segment_label: str,
               category_code: tuple[str, str, str],
               type_code:    tuple[str, str, str],
               algorithm_name: str,
               algorithm_version: str,
               algorithm_type: str,
               series_uid: str,
               instance_uid: str,
               series_number: int,
               instance_number: int,
               series_description: str) -> Segmentation:
    source_images = [pydicom.dcmread(str(p)) for p in reference_paths]
    description = _build_segment(
        label            = segment_label,
        category_code    = category_code,
        type_code        = type_code,
        algorithm_name   = algorithm_name,
        algorithm_version= algorithm_version,
        algorithm_type   = algorithm_type,
    )
    seg = Segmentation(
        source_images        = source_images,
        pixel_array          = mask,
        segmentation_type    = SegmentationTypeValues.BINARY,
        segment_descriptions = [description],
        series_instance_uid  = series_uid,
        series_number        = series_number,
        sop_instance_uid     = instance_uid,
        instance_number      = instance_number,
        manufacturer         = "DicomSegRuby",
        manufacturer_model_name = "dicom_seg-ruby",
        software_versions    = "0.1.0",
        device_serial_number = "0001",
        content_label        = CONTENT_LABEL,
        content_description  = CONTENT_DESCRIPTION,
        content_creator_name = CONTENT_CREATOR_NAME,
        series_description   = series_description,
        transfer_syntax_uid  = ExplicitVRLittleEndian,
    )
    # Pin deterministic content date/time.
    seg.ContentDate = CONTENT_DATE
    seg.ContentTime = CONTENT_TIME
    seg.InstanceCreationDate = CONTENT_DATE
    seg.InstanceCreationTime = CONTENT_TIME
    if hasattr(seg, "SeriesDate"):
        seg.SeriesDate = CONTENT_DATE
    if hasattr(seg, "SeriesTime"):
        seg.SeriesTime = CONTENT_TIME
    # Pin DimensionOrganizationUID across both sequences.
    for item in seg.DimensionOrganizationSequence:
        item.DimensionOrganizationUID = DIMENSION_ORG_UID
    for item in seg.DimensionIndexSequence:
        item.DimensionOrganizationUID = DIMENSION_ORG_UID
    return seg


def _format_value(elem) -> object:
    """Recursively dump an element into JSON/YAML-safe primitives."""
    if elem.tag == 0x7FE00010:  # PixelData
        return {"sha256": hashlib.sha256(elem.value).hexdigest(),
                "length": len(elem.value)}
    if elem.VR == "SQ":
        return [_dump_dataset(item) for item in elem.value]
    v = elem.value
    if isinstance(v, bytes):
        return {"hex": v.hex()}
    if isinstance(v, pydicom.multival.MultiValue):
        return [_atom(x) for x in v]
    if isinstance(v, list):
        return [_atom(x) for x in v]
    if isinstance(v, pydicom.valuerep.PersonName):
        return str(v)
    if isinstance(v, pydicom.uid.UID):
        return str(v)
    return _atom(v)


def _atom(v):
    if isinstance(v, (pydicom.valuerep.DSfloat, pydicom.valuerep.DSdecimal)):
        return str(v)
    if isinstance(v, pydicom.valuerep.IS):
        return int(v)
    if isinstance(v, pydicom.valuerep.PersonName):
        return str(v)
    if isinstance(v, pydicom.uid.UID):
        return str(v)
    if isinstance(v, pydicom.tag.BaseTag):
        return f"{v.group:04X},{v.element:04X}"
    if isinstance(v, bytes):
        return {"hex": v.hex()}
    if isinstance(v, float):
        return v
    if isinstance(v, int):
        return v
    return str(v)


def _dump_dataset(ds: Dataset) -> list[dict]:
    out = []
    for elem in ds:
        out.append({
            "tag":   f"{elem.tag.group:04X},{elem.tag.element:04X}",
            "vr":    elem.VR,
            "name":  elem.name,
            "value": _format_value(elem),
        })
    return out


def _dump_file_meta(ds: Dataset) -> list[dict]:
    return _dump_dataset(ds.file_meta)


class _QuotedTagDumper(yaml.SafeDumper):
    """SafeDumper that forces double-quoted style for tag-like strings.

    Ruby's YAML reader interprets strings of the form 'XXXX,YYYY' as the
    integer XXXX*4096+YYYY when unquoted, which breaks element-by-element
    comparison of the elements.yaml golden. We solve that by always emitting
    strings (especially tag strings) in double-quoted scalar style.
    """


def _str_repr(dumper, data):
    return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='"')


_QuotedTagDumper.add_representer(str, _str_repr)


def _write_golden(name: str, seg: Segmentation):
    GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
    dcm_path = GOLDEN_DIR / f"{name}.dcm"
    seg.save_as(str(dcm_path))

    # Re-read so element values are normalized exactly as pydicom would present them.
    reread = pydicom.dcmread(str(dcm_path))
    elements_doc = {
        "file_meta": _dump_file_meta(reread),
        "dataset":   _dump_dataset(reread),
    }
    (GOLDEN_DIR / f"{name}.elements.yaml").write_text(
        yaml.dump(elements_doc,
                  Dumper=_QuotedTagDumper,
                  sort_keys=False,
                  default_flow_style=False,
                  allow_unicode=True)
    )
    (GOLDEN_DIR / f"{name}.pixel_data.bin").write_bytes(reread.PixelData)
    print(f"[golden] wrote {name}: {dcm_path.stat().st_size} bytes")


def scenario_single_slice_humerus():
    mask = np.zeros((1, 128, 128), dtype=np.uint8)
    # 16x16 centered square (rows 56..71, cols 56..71 inclusive)
    mask[0, 56:72, 56:72] = 1
    seg = _build_seg(
        reference_paths    = [SOURCE_CT],
        mask               = mask,
        segment_label      = "Humerus",
        category_code      = ("T-D0050", "SRT", "Tissue"),
        type_code          = ("T-12410", "SRT", "Humerus"),
        algorithm_name     = "test-segmenter",
        algorithm_version  = "0.1.0",
        algorithm_type     = "MANUAL",
        series_uid         = SERIES_UID,
        instance_uid       = INSTANCE_UID,
        series_number      = SERIES_NUMBER,
        instance_number    = INSTANCE_NUMBER,
        series_description = "Humerus Segmentation",
    )
    _write_golden("single_slice_humerus", seg)


def scenario_multi_slice_bone():
    slice_paths = _synthesize_multi_slice_series(num_slices=4)
    mask = np.zeros((4, 128, 128), dtype=np.uint8)
    # 64x64 centered cube on all 4 slices: rows 32..95, cols 32..95 inclusive.
    mask[:, 32:96, 32:96] = 1
    seg = _build_seg(
        reference_paths    = slice_paths,
        mask               = mask,
        segment_label      = "Bone",
        category_code      = ("T-D0050", "SRT", "Tissue"),
        type_code          = ("T-D0146", "SRT", "Bone"),
        algorithm_name     = "test-segmenter",
        algorithm_version  = "0.1.0",
        algorithm_type     = "MANUAL",
        series_uid         = MULTI_SERIES_UID,
        instance_uid       = MULTI_INSTANCE_UID,
        series_number      = SERIES_NUMBER,
        instance_number    = INSTANCE_NUMBER,
        series_description = "Bone Segmentation",
    )
    _write_golden("multi_slice_bone", seg)


def main():
    if not SOURCE_CT.exists():
        print(f"ERROR: source CT not found at {SOURCE_CT}", file=sys.stderr)
        sys.exit(2)
    GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    scenario_single_slice_humerus()
    scenario_multi_slice_bone()
    print("Done.")


if __name__ == "__main__":
    main()
