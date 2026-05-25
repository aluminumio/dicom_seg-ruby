# dicom_seg-ruby

Ruby writer for DICOM **Segmentation Storage** SOP-Class objects
(`1.2.840.10008.5.1.4.1.1.66.4`), with output verified element-by-element
against Python's [`highdicom`](https://github.com/imagingdatacommons/highdicom).

Phase 1 supports **binary, single-segment** segmentations that reference an
existing CT series. Reader support, fractional segmentation, multi-segment, and
label-map encoding are later phases.

## Installation

```ruby
gem "dicom_seg"
```

Requires Ruby 3.3+ and the `dicom` gem (added as a runtime dependency).

## Usage

```ruby
require "dicom_seg"

seg = DicomSeg.build(
  reference_dicoms: ["/path/series/slice_001.dcm", "/path/series/slice_002.dcm"],
  mask: numo_or_array,             # 3D: mask[k][j][i] for slice k, row j, col i
  segment: {
    label:      "Humerus",
    algorithm:  { name: "test-segmenter", version: "0.1.0", type: "MANUAL" },
    category:   { code: "T-D0050", scheme: "SRT", meaning: "Tissue" },
    type:       { code: "T-12410", scheme: "SRT", meaning: "Humerus" }
  },
  series_uid:      "1.2.3.test.series",
  instance_uid:    "1.2.3.test.instance",
  series_number:   1001,
  instance_number: 1,
  series_description: "Humerus Segmentation"
)

seg.to_dataset   # => DICOM::DObject from the `dicom` gem
seg.write(path)  # => writes the .dcm file
```

The `mask` is any 3-D structure indexable as `mask[k][j][i]`. For Phase 1 plain
Ruby `Array` of `Array` of `Array` of 0/1 (or truthy values) is fine — no
`numo-narray` dependency.

### Optional inputs (with defaults)

| Argument                      | Default                  |
|-------------------------------|--------------------------|
| `manufacturer`                | `"DicomSegRuby"`         |
| `manufacturer_model_name`     | `"dicom_seg-ruby"`       |
| `software_versions`           | `DicomSeg::VERSION`      |
| `device_serial_number`        | `"0001"`                 |
| `content_label`               | `"SEGMENTATION"`         |
| `content_description`         | `""`                     |
| `content_creator_name`        | `"Unknown^Unknown"`      |
| `content_date`                | today (UTC, `YYYYMMDD`)  |
| `content_time`                | now (UTC, `HHMMSS.ffffff`) |
| `dimension_organization_uid`  | generated under `1.2.826.0.1.3680043.10.511.3.` |

## Spec-first workflow

This gem uses **highdicom** as a golden oracle. The Python script in
`script/regenerate_golden.py` runs each scenario through `highdicom` and writes
three artifacts under `spec/golden/`:

* `<scenario>.dcm` — the highdicom-produced SEG
* `<scenario>.elements.yaml` — every top-level Data Element, recursively
* `<scenario>.pixel_data.bin` — raw packed-bits PixelData

Ruby specs then write the same scenario via this gem and assert
**element-by-element equivalence** with the golden YAML, plus byte-identical
PixelData.

### Regenerating goldens

```bash
python3 -m venv .venv
.venv/bin/pip install -r script/requirements.txt
.venv/bin/python script/regenerate_golden.py
```

The script writes to `spec/golden/` and synthesizes a multi-slice reference
series in `spec/fixtures/ct_small_series/` by copying
`dicom-imager/spec/fixtures/files/CT_small.dcm` four times with bumped
`ImagePositionPatient` and unique `SOPInstanceUID`s.

### Running specs

```bash
bundle install
bundle exec rspec
```

## Intentional deviations from highdicom

The following Data Elements differ between Ruby and highdicom output and are
allow-listed in `spec/spec_helper.rb` (`INTENTIONAL_DIFFS`):

| Tag         | Element                              | Reason |
|-------------|--------------------------------------|--------|
| `(0002,0000)` | File Meta Information Group Length  | Auto-computed; differs because of the two fields below. |
| `(0002,0012)` | Implementation Class UID            | Identifies the writing toolkit. |
| `(0002,0013)` | Implementation Version Name         | Identifies the writing toolkit. |

The dicom Ruby gem also encodes sequences/items with **undefined length**
(`0xFFFFFFFF`) rather than highdicom's defined-length sequences. This is a
byte-level difference but semantically identical — both forms round-trip
through any DICOM reader. The Ruby output is therefore ~8 bytes larger per
sequence/item than the highdicom output, but the decoded element trees are
identical. The (`0002,0016`) Source Application Entity Title element that the
`dicom` gem inserts automatically is stripped from the output to keep parity
with highdicom (which does not emit it).

## DICOM SEG IOD reference

NEMA Part 3, A.51:
https://dicom.nema.org/medical/dicom/current/output/html/part03.html#sect_A.51

## License

MIT
