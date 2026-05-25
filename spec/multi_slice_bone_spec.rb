require "spec_helper"
require "tmpdir"

RSpec.describe "multi_slice_bone scenario" do
  let(:golden_yaml)  { YAML.load_file(File.join(GOLDEN_DIR, "multi_slice_bone.elements.yaml")) }
  let(:golden_pixel) { File.binread(File.join(GOLDEN_DIR, "multi_slice_bone.pixel_data.bin")) }

  let(:reference_paths) { Dir[File.join(MULTI_SERIES_DIR, "slice_*.dcm")].sort }

  # 4 frames, each 128x128, centered 64x64 cube (rows 32..95, cols 32..95).
  let(:mask) do
    Array.new(4) do
      Array.new(128) do |j|
        Array.new(128) do |i|
          (j.between?(32, 95) && i.between?(32, 95)) ? 1 : 0
        end
      end
    end
  end

  let(:builder) do
    DicomSeg.build(
      reference_dicoms:           reference_paths,
      mask:                       mask,
      segment: {
        label:      "Bone",
        algorithm:  { name: "test-segmenter", version: "0.1.0", type: "MANUAL" },
        category:   { code: "T-D0050", scheme: "SRT", meaning: "Tissue" },
        type:       { code: "T-D0146", scheme: "SRT", meaning: "Bone" }
      },
      series_uid:                 GoldenConstants::MULTI_SERIES_UID,
      instance_uid:               GoldenConstants::MULTI_INSTANCE_UID,
      series_number:              GoldenConstants::SERIES_NUMBER,
      instance_number:            GoldenConstants::INSTANCE_NUMBER,
      series_description:         "Bone Segmentation",
      manufacturer:               GoldenConstants::MANUFACTURER,
      manufacturer_model_name:    GoldenConstants::MANUFACTURER_MODEL_NAME,
      software_versions:          GoldenConstants::SOFTWARE_VERSIONS,
      device_serial_number:       GoldenConstants::DEVICE_SERIAL_NUMBER,
      content_label:              GoldenConstants::CONTENT_LABEL,
      content_description:        GoldenConstants::CONTENT_DESCRIPTION,
      content_creator_name:       GoldenConstants::CONTENT_CREATOR_NAME,
      content_date:               GoldenConstants::CONTENT_DATE,
      content_time:               GoldenConstants::CONTENT_TIME,
      dimension_organization_uid: GoldenConstants::DIMENSION_ORG_UID,
    )
  end

  let(:tmpdir) { Dir.mktmpdir("dicom_seg_test_") }
  let(:out_path) { File.join(tmpdir, "out.dcm") }
  after { FileUtils.remove_entry(tmpdir) if File.exist?(tmpdir) }

  let(:written) do
    builder.write(out_path)
    DICOM::DObject.read(out_path)
  end

  it "loads via the dicom gem and identifies as SEG" do
    expect(written.value("0008,0016")).to eq("1.2.840.10008.5.1.4.1.1.66.4")
    expect(written.value("0008,0060")).to eq("SEG")
    expect(written.value("0028,0008").to_i).to eq(4)
  end

  it "matches the highdicom dataset element-by-element" do
    ruby_ds = ElementDump.dump_dataset(written).reject { |e| e["tag"].start_with?("0002,") }
    gold_ds = golden_yaml["dataset"]

    expect(ruby_ds.map { |e| e["tag"] }).to eq(gold_ds.map { |e| e["tag"] })

    ruby_ds.zip(gold_ds).each do |r, g|
      expect(r["vr"]).to eq(g["vr"]),
        "VR mismatch at #{r['tag']} (#{r['name']}): ruby=#{r['vr']} gold=#{g['vr']}"
      expect(r["value"]).to eq(g["value"]),
        "Value mismatch at #{r['tag']} (#{r['name']}): \nruby=#{r['value'].inspect}\ngold=#{g['value'].inspect}"
    end
  end

  it "produces packed-bits PixelData exactly equal to the golden bytes" do
    expect(written["7FE0,0010"].bin).to eq(golden_pixel)
  end

  it "orders per-frame items by descending z (matching highdicom)" do
    pf_seq = written["5200,9230"]
    expect(pf_seq.items.length).to eq(4)
    zs = pf_seq.items.map do |it|
      it["0020,9113"].items.first["0020,0032"].value.split("\\").map(&:to_f).last
    end
    expect(zs).to eq(zs.sort.reverse)
  end

  it "uses the correct per-frame DimensionIndexValues (segment=1, slice=1..N)" do
    pf_seq = written["5200,9230"]
    divs = pf_seq.items.map do |it|
      it["0020,9111"].items.first["0020,9157"].bin.unpack("V*")
    end
    expect(divs).to eq([[1, 1], [1, 2], [1, 3], [1, 4]])
  end

  it "lists referenced source SOP Instance UIDs in input order" do
    rs_seq = written["0008,1115"].items.first["0008,114A"]
    refs = rs_seq.items.map { |it| it["0008,1155"].value }
    expect(refs).to eq([
      "1.2.826.0.1.3680043.10.511.3.123.4567.200.1",
      "1.2.826.0.1.3680043.10.511.3.123.4567.200.2",
      "1.2.826.0.1.3680043.10.511.3.123.4567.200.3",
      "1.2.826.0.1.3680043.10.511.3.123.4567.200.4",
    ])
  end
end
