require "spec_helper"
require "tmpdir"

RSpec.describe "single_slice_humerus scenario" do
  let(:golden_dcm)   { File.join(GOLDEN_DIR, "single_slice_humerus.dcm") }
  let(:golden_yaml)  { YAML.load_file(File.join(GOLDEN_DIR, "single_slice_humerus.elements.yaml")) }
  let(:golden_pixel) { File.binread(File.join(GOLDEN_DIR, "single_slice_humerus.pixel_data.bin")) }

  # Build a 1x128x128 mask with a centered 16x16 square (rows 56..71, cols 56..71).
  let(:mask) do
    Array.new(1) do
      Array.new(128) do |j|
        Array.new(128) do |i|
          (j.between?(56, 71) && i.between?(56, 71)) ? 1 : 0
        end
      end
    end
  end

  let(:builder) do
    DicomSeg.build(
      reference_dicoms:           [SOURCE_CT_SMALL],
      mask:                       mask,
      segment: {
        label:      "Humerus",
        algorithm:  { name: "test-segmenter", version: "0.1.0", type: "MANUAL" },
        category:   { code: "T-D0050", scheme: "SRT", meaning: "Tissue" },
        type:       { code: "T-12410", scheme: "SRT", meaning: "Humerus" }
      },
      series_uid:                 GoldenConstants::SINGLE_SERIES_UID,
      instance_uid:               GoldenConstants::SINGLE_INSTANCE_UID,
      series_number:              GoldenConstants::SERIES_NUMBER,
      instance_number:            GoldenConstants::INSTANCE_NUMBER,
      series_description:         "Humerus Segmentation",
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

  it "writes a SEG file that loads via the dicom gem" do
    expect(written).to be_a(DICOM::DObject)
    expect(written.value("0008,0016")).to eq("1.2.840.10008.5.1.4.1.1.66.4")
    expect(written.value("0008,0060")).to eq("SEG")
  end

  it "matches the highdicom file_meta element-by-element (modulo toolkit identity)" do
    ruby_meta = ElementDump.dump_dataset(written).select { |e| e["tag"].start_with?("0002,") } +
                # The dicom gem stores file meta at the same level as dataset.
                # Filter explicitly:
                []
    ruby_meta = ElementDump.dump_dataset(written).select { |e| e["tag"].start_with?("0002,") }
    gold_meta = golden_yaml["file_meta"]

    ruby_filtered  = ruby_meta.reject { |e| INTENTIONAL_DIFFS.key?(e["tag"]) }
    gold_filtered  = gold_meta.reject { |e| INTENTIONAL_DIFFS.key?(e["tag"]) }

    expect(ruby_filtered.map { |e| e["tag"] }).to eq(gold_filtered.map { |e| e["tag"] })
    ruby_filtered.zip(gold_filtered).each do |r, g|
      expect(r["vr"]).to eq(g["vr"]),     "VR mismatch on #{r['tag']}: ruby=#{r['vr']} gold=#{g['vr']}"
      expect(r["value"]).to eq(g["value"]),
        "value mismatch on #{r['tag']}: ruby=#{r['value'].inspect} gold=#{g['value'].inspect}"
    end
  end

  it "matches the highdicom dataset element-by-element (every tag, vr, and value)" do
    ruby_ds = ElementDump.dump_dataset(written).reject { |e| e["tag"].start_with?("0002,") }
    gold_ds = golden_yaml["dataset"]

    # 1. Same tag set in the same order.
    expect(ruby_ds.map { |e| e["tag"] }).to eq(gold_ds.map { |e| e["tag"] })

    # 2. Each element matches VR + value (sequences compared recursively via deep equality).
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

  it "has one per-frame functional groups item with the expected attributes" do
    pf_seq = written["5200,9230"]
    expect(pf_seq.items.length).to eq(1)
    item = pf_seq.items.first
    ipp = item["0020,9113"].items.first["0020,0032"].value
    expect(ipp).to eq("-158.135803\\-179.035797\\-75.699997")
    div_bin = item["0020,9111"].items.first["0020,9157"].bin
    expect(div_bin.unpack("V*")).to eq([1, 1])
    rsn = item["0062,000A"].items.first["0062,000B"].value
    expect(rsn).to eq(1)
    src = item["0008,9124"].items.first["0008,2112"].items.first
    expect(src["0008,1155"].value).to eq("1.3.6.1.4.1.5962.1.1.1.1.1.20040119072730.12322")
  end
end
