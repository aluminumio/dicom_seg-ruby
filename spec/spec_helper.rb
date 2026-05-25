require "yaml"
require "digest"
require "dicom"
require "dicom_seg"

DICOM.logger.level = Logger::ERROR

PROJECT_ROOT = File.expand_path("..", __dir__)
GOLDEN_DIR   = File.join(PROJECT_ROOT, "spec", "golden")
FIXTURES_DIR = File.join(PROJECT_ROOT, "spec", "fixtures")

# Deterministic constants — must match script/regenerate_golden.py.
module GoldenConstants
  SINGLE_SERIES_UID            = "1.2.826.0.1.3680043.10.511.3.123.4567.1"
  SINGLE_INSTANCE_UID          = "1.2.826.0.1.3680043.10.511.3.123.4567.2"
  MULTI_SERIES_UID             = "1.2.826.0.1.3680043.10.511.3.123.4567.300"
  MULTI_INSTANCE_UID           = "1.2.826.0.1.3680043.10.511.3.123.4567.301"
  DIMENSION_ORG_UID            = "1.2.826.0.1.3680043.10.511.3.123.4567.10"
  CONTENT_DATE                 = "20260101"
  CONTENT_TIME                 = "120000.000000"
  CONTENT_CREATOR_NAME         = "Doe^Jane"
  CONTENT_LABEL                = "BONE_SEG"
  CONTENT_DESCRIPTION          = "Phase 1 fixture"
  SERIES_NUMBER                = 1001
  INSTANCE_NUMBER              = 1
  MANUFACTURER                 = "DicomSegRuby"
  MANUFACTURER_MODEL_NAME      = "dicom_seg-ruby"
  SOFTWARE_VERSIONS            = "0.1.0"
  DEVICE_SERIAL_NUMBER         = "0001"
end

SOURCE_CT_SMALL = "/Users/jonathan/Projects/dicom-imager/spec/fixtures/files/CT_small.dcm"
MULTI_SERIES_DIR = File.join(FIXTURES_DIR, "ct_small_series")

# Tags whose values are allowed to differ between Ruby's output and the
# highdicom golden. These identify the *toolkit* that wrote the file, not
# the SOP-Class content, so any conformant writer will produce different
# values here.
INTENTIONAL_DIFFS = {
  "0002,0000" => "File Meta Information Group Length (auto-computed, depends on toolkit fields)",
  "0002,0012" => "Implementation Class UID (identifies dicom_seg-ruby vs highdicom)",
  "0002,0013" => "Implementation Version Name (identifies dicom_seg-ruby vs highdicom)",
}.freeze

module ElementDump
  module_function

  # Convert a DICOM::DObject (or any parent with .children) into the same
  # structure used by the Python golden dumper: [{tag:, vr:, name:, value:}, ...].
  # We use #children because the dicom gem's #elements excludes Sequences.
  def dump_dataset(parent)
    parent.children.map { |el| dump_element(el) }
  end

  def dump_element(el)
    {
      "tag"  => el.tag,
      "vr"   => el.vr,
      "name" => el.name,
      "value" => dump_value(el),
    }
  end

  STRING_VRS = %w[AE AS CS DA DT LO LT PN SH ST TM UI UT].freeze

  def dump_value(el)
    if el.tag == "7FE0,0010"
      { "sha256" => Digest::SHA256.hexdigest(el.bin), "length" => el.bin.bytesize }
    elsif el.is_a?(DICOM::Sequence)
      el.items.map { |item| dump_dataset(item) }
    elsif el.vr == "OB" || el.vr == "OW" || el.vr == "UN"
      { "hex" => el.bin.unpack1("H*") }
    elsif el.vr == "AT"
      # AT values are 4 raw bytes (group/elem little-endian). Format as "GGGG,EEEE".
      raw = el.bin
      group, elem = raw.unpack("v v")
      "%04X,%04X" % [group, elem]
    else
      v = el.value
      # The dicom gem returns nil for empty string-typed elements (the bin
      # is genuinely 0 bytes); pydicom surfaces these as "". Normalize.
      v = "" if v.nil? && STRING_VRS.include?(el.vr)
      if v.is_a?(String) && v.include?("\\")
        v.split("\\").map { |x| coerce_atom(x, el.vr) }
      elsif el.vr == "UL" || el.vr == "US" || el.vr == "SL" || el.vr == "SS"
        if v.is_a?(String)
          v.split("\\").map(&:to_i)
        else
          v.is_a?(Integer) ? v : v.to_i
        end
      elsif el.vr == "IS"
        v.is_a?(Integer) ? v : v.to_i
      else
        v
      end
    end
  end

  def coerce_atom(s, vr)
    case vr
    when "UL", "US", "SL", "SS" then s.to_i
    when "IS"                   then s.to_i
    else s
    end
  end
end
