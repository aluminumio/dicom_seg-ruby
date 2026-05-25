require_relative "lib/dicom_seg/version"

Gem::Specification.new do |spec|
  spec.name          = "dicom_seg"
  spec.version       = DicomSeg::VERSION
  spec.authors       = ["Aluminum IO"]
  spec.email         = ["dev@aluminum.io"]

  spec.summary       = "Ruby writer for DICOM Segmentation Storage SOP-Class objects."
  spec.description   = "Build DICOM SEG (1.2.840.10008.5.1.4.1.1.66.4) files in pure Ruby, " \
                       "with byte-for-byte fidelity to Python's highdicom for binary segmentations."
  spec.homepage      = "https://github.com/aluminumio/dicom_seg-ruby"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "dicom_seg.gemspec"]
  spec.require_paths = ["lib"]

  spec.add_dependency "dicom", "~> 0.9"

  spec.add_development_dependency "bundler", ">= 2.4"
  spec.add_development_dependency "rspec", "~> 3.13"
end
