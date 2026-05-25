require "spec_helper"
require "tmpdir"

RSpec.describe "Builder error cases" do
  let(:reference_paths) { Dir[File.join(MULTI_SERIES_DIR, "slice_*.dcm")].sort }

  let(:base_segment) do
    {
      label:      "Bone",
      algorithm:  { name: "x", version: "1", type: "MANUAL" },
      category:   { code: "T-D0050", scheme: "SRT", meaning: "Tissue" },
      type:       { code: "T-D0146", scheme: "SRT", meaning: "Bone" }
    }
  end

  let(:base_kwargs) do
    {
      segment:                    base_segment,
      series_uid:                 "1.2.3.test",
      instance_uid:               "1.2.3.test.inst",
      series_number:              1,
      instance_number:            1,
      series_description:         "test",
      dimension_organization_uid: GoldenConstants::DIMENSION_ORG_UID,
    }
  end

  it "raises if mask depth does not match reference DICOM count" do
    bad_mask = Array.new(2) { Array.new(128) { Array.new(128, 0) } }
    expect {
      DicomSeg.build(reference_dicoms: reference_paths, mask: bad_mask, **base_kwargs)
    }.to raise_error(ArgumentError, /mask depth \(2\) must match number of reference DICOMs \(4\)/)
  end

  it "raises if reference DICOMs come from different series" do
    mixed = [SOURCE_CT_SMALL, reference_paths.first]
    mask = Array.new(2) { Array.new(128) { Array.new(128, 0) } }
    expect {
      DicomSeg.build(reference_dicoms: mixed, mask: mask, **base_kwargs)
    }.to raise_error(ArgumentError, /all reference DICOMs must share SeriesInstanceUID/)
  end

  it "accepts an empty mask and produces zero per-frame items" do
    empty = Array.new(4) { Array.new(128) { Array.new(128, 0) } }
    b = DicomSeg.build(reference_dicoms: reference_paths, mask: empty, **base_kwargs)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "empty.dcm")
      b.write(path)
      d = DICOM::DObject.read(path)
      pf_seq = d["5200,9230"]
      # Either the sequence is absent or it has zero items — both valid.
      expect(pf_seq.nil? || pf_seq.items.length.zero?).to be(true)
      expect(d.value("0028,0008").to_i).to eq(0)
      expect(b.per_frame_items.length).to eq(0)
      pd = d["7FE0,0010"]
      expect(pd.nil? || pd.bin.bytesize.zero?).to be(true)
    end
  end

  it "raises a clear error if mask is nil" do
    expect {
      DicomSeg.build(reference_dicoms: reference_paths, mask: nil, **base_kwargs)
    }.to raise_error(ArgumentError, /mask must be provided/)
  end
end
