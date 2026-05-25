require "dicom"
require_relative "dicom_seg/version"
require_relative "dicom_seg/ds"
require_relative "dicom_seg/pixel_packing"
require_relative "dicom_seg/builder"

# Silence the `dicom` gem's INFO-level chatter during load — callers can
# override by setting DICOM.logger.level themselves.
DICOM.logger.level = Logger::WARN if defined?(DICOM.logger) && defined?(Logger)

module DicomSeg
  class Error < StandardError; end

  # Top-level convenience constructor mirroring the public API spec.
  def self.build(**kwargs)
    Builder.new(**kwargs)
  end

  # Generate a deterministic-ish UID under the given root by hashing the caller
  # — used only as a fallback for the dimension organization UID when the
  # caller doesn't supply one.
  def self.generate_uid(root)
    suffix = (Time.now.to_f * 1_000_000).to_i.to_s + rand(10**9).to_s
    "#{root}#{suffix}"[0, 64]
  end
end
