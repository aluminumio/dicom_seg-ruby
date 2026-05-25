require "spec_helper"

RSpec.describe DicomSeg::DS do
  it "formats short floats with shortest round-trip representation" do
    expect(described_class.format_value(5.0)).to eq("5.0")
    expect(described_class.format_value(0.661468)).to eq("0.661468")
    expect(described_class.format_value(-75.699997)).to eq("-75.699997")
    expect(described_class.format_value(0.0)).to eq("0.0")
    expect(described_class.format_value(1.0)).to eq("1.0")
  end

  it "expands non-round floats up to the 16-char DS limit" do
    # -75.699997 + 15.0 in IEEE 754 = -60.699996999999996 (string len 19);
    # pydicom formats that as "-60.699997000000" — match.
    expect(described_class.format_value(-75.699997 + 15.0)).to eq("-60.699997000000")
  end

  it "raises on non-finite values" do
    expect { described_class.format_value(Float::INFINITY) }.to raise_error(ArgumentError)
  end

  it "raises on non-numeric input" do
    expect { described_class.format_value("not a number") }.to raise_error(TypeError)
  end
end
