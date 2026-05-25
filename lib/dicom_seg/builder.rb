require "dicom"
require_relative "ds"

module DicomSeg
  # ----------------------------------------------------------------------------
  # DICOM Segmentation Storage IOD (SOP Class 1.2.840.10008.5.1.4.1.1.66.4).
  #
  # IOD reference: NEMA Part 3, A.51
  # https://dicom.nema.org/medical/dicom/current/output/html/part03.html#sect_A.51
  #
  # Modules used by this Phase 1 builder (matching highdicom 0.24.0 output for
  # a BINARY, single-segment SEG referencing a CT series):
  #
  #   Patient                       (copied from reference DICOM)
  #   Clinical Trial Subject        (copied if present)            -- not handled
  #   General Study                 (copied from reference DICOM)
  #   Patient Study                 (copied if present)
  #   Clinical Trial Study          (copied if present)            -- not handled
  #   Segmentation Series           (set: Modality=SEG, SeriesInstanceUID, ...)
  #   Frame of Reference            (copied from reference DICOM)
  #   General Equipment             (set: Manufacturer, ...)
  #   General Image                 (Image Type)
  #   Multi-frame Functional Groups (Shared + Per-Frame groups)
  #   Multi-frame Dimension         (DimensionOrganizationSequence, DimensionIndexSequence)
  #   Specimen                                                     -- not handled
  #   Segmentation Image            (BitsAllocated=1, BinaryFractional, SegmentSequence, ...)
  #   Common Instance Reference     (ReferencedSeriesSequence)
  #   SOP Common                    (SOPClassUID, SOPInstanceUID, ContentDate, ...)
  # ----------------------------------------------------------------------------
  class Builder
    SEG_SOP_CLASS_UID  = "1.2.840.10008.5.1.4.1.1.66.4"
    EXPLICIT_VR_LE_TS  = "1.2.840.10008.1.2.1"

    attr_reader :reference_dicoms, :mask, :segment, :series_uid, :instance_uid,
                :series_number, :instance_number, :series_description,
                :manufacturer, :manufacturer_model_name, :software_versions,
                :device_serial_number, :content_label, :content_description,
                :content_creator_name, :content_date, :content_time,
                :dimension_organization_uid

    # `mask` is mask[k][j][i] — frame k, row j, col i. Binary 0/1.
    def initialize(reference_dicoms:, mask:, segment:,
                   series_uid:, instance_uid:,
                   series_number:, instance_number:,
                   series_description:,
                   manufacturer: "DicomSegRuby",
                   manufacturer_model_name: "dicom_seg-ruby",
                   software_versions: DicomSeg::VERSION,
                   device_serial_number: "0001",
                   content_label: "SEGMENTATION",
                   content_description: "",
                   content_creator_name: "Unknown^Unknown",
                   content_date: Time.now.utc.strftime("%Y%m%d"),
                   content_time: Time.now.utc.strftime("%H%M%S.%6N"),
                   dimension_organization_uid: nil)
      @reference_dicoms       = reference_dicoms
      @mask                   = mask
      @segment                = segment
      @series_uid             = series_uid
      @instance_uid           = instance_uid
      @series_number          = series_number
      @instance_number        = instance_number
      @series_description     = series_description
      @manufacturer           = manufacturer
      @manufacturer_model_name = manufacturer_model_name
      @software_versions      = software_versions
      @device_serial_number   = device_serial_number
      @content_label          = content_label
      @content_description    = content_description
      @content_creator_name   = content_creator_name
      @content_date           = content_date
      @content_time           = content_time
      @dimension_organization_uid = dimension_organization_uid ||
                                    DicomSeg.generate_uid("1.2.826.0.1.3680043.10.511.3.")
      validate!
    end

    def to_dataset
      @dataset ||= build_dataset
    end

    def write(path)
      dataset = to_dataset
      dataset.write(path)
      # The `dicom` gem unconditionally inserts 0002,0016 (Source Application
      # Entity Title) during write; highdicom never emits that element. Strip
      # it from the on-disk file so the byte stream matches the IOD highdicom
      # produces. The element is non-required by the SEG IOD.
      strip_source_aet(path)
      path
    end

    # Tuples of {sop_instance_uid:, image_position_patient: [x,y,z],
    # frame_index: source_index, has_content: bool, source_path:}
    def reference_slices
      @reference_slices ||= load_reference_slices
    end

    # The per-frame items, sorted by z-projection descending (matches highdicom).
    # Only frames whose mask has at least one positive voxel are included.
    def per_frame_items
      @per_frame_items ||= begin
        items = reference_slices.each_with_index.map do |slice, frame_index|
          slice.merge(frame_index: frame_index,
                      has_content: frame_has_content?(frame_index))
        end
        # Filter to frames with positive voxels, then sort by z (descending),
        # which matches highdicom's spatial ordering for 3D Plane Position dim.
        items.select { |s| s[:has_content] }
             .sort_by { |s| -s[:image_position_patient][2] }
      end
    end

    private

    # Re-open the just-written file and remove the auto-inserted (0002,0016)
    # element. Recompute (0002,0000) group length accordingly. Done as a
    # post-pass because the `dicom` gem inserts the element internally on
    # every write; we therefore re-write with :ignore_meta to keep our hand-
    # crafted file_meta verbatim.
    def strip_source_aet(path)
      d = DICOM::DObject.read(path)
      return unless d["0002,0016"]
      d.delete("0002,0016")
      # Recompute group length manually (insert_missing_meta is skipped via
      # :ignore_meta below).
      d.delete("0002,0000")
      d.add(DICOM::Element.new("0002,0000", meta_group_length(d)))
      d.write(path, ignore_meta: true)
    end

    # Compute (0002,0000) FileMetaInformationGroupLength: bytes occupied by
    # all (0002,xxxx) elements after (0002,0000) itself. For Explicit VR LE
    # each element header is 8 bytes for short-VR elements (UI/UL/SH/OB), or
    # 12 bytes for the OB VR (which uses a 4-byte length field with 2 reserved
    # bytes). 0002,0001 (OB), 0002,0010 (UI), 0002,0002 (UI), 0002,0003 (UI),
    # 0002,0012 (UI), 0002,0013 (SH).
    def meta_group_length(d)
      total = 0
      d.elements.each do |e|
        next unless e.tag.start_with?("0002,")
        next if e.tag == "0002,0000"
        header = (e.vr == "OB" || e.vr == "OW" || e.vr == "OF" ||
                  e.vr == "SQ" || e.vr == "UT" || e.vr == "UN") ? 12 : 8
        total += header + e.bin.bytesize
      end
      total
    end

    def validate!
      raise ArgumentError, "mask must be provided" if mask.nil?
      raise ArgumentError, "mask must be a 3D structure" unless mask.respond_to?(:[]) && mask[0].respond_to?(:[])
      mask_depth = mask.length
      ref_count  = reference_dicoms.length
      if mask_depth != ref_count
        raise ArgumentError,
              "mask depth (#{mask_depth}) must match number of reference DICOMs (#{ref_count})"
      end
      raise ArgumentError, "reference_dicoms must not be empty" if ref_count.zero?

      series_uids = reference_dicoms.map { |p| read_dicom(p).value("0020,000E") }.uniq
      if series_uids.length > 1
        raise ArgumentError,
              "all reference DICOMs must share SeriesInstanceUID; saw #{series_uids.inspect}"
      end
    end

    def read_dicom(path)
      @dicom_cache ||= {}
      @dicom_cache[path] ||= DICOM::DObject.read(path)
    end

    def load_reference_slices
      reference_dicoms.map do |path|
        d = read_dicom(path)
        ipp_str = d.value("0020,0032").to_s
        ipp = ipp_str.split("\\").map(&:to_f)
        {
          path: path,
          sop_class_uid:    d.value("0008,0016"),
          sop_instance_uid: d.value("0008,0018"),
          image_position_patient: ipp,
        }
      end
    end

    def frame_has_content?(frame_index)
      frame = mask[frame_index]
      frame.any? { |row| row.any? { |v| v.to_i != 0 } }
    end

    def reference_series_uid
      @reference_series_uid ||= read_dicom(reference_dicoms.first).value("0020,000E")
    end

    # Return the original DS-encoded string for these reference attributes
    # so we preserve pydicom's "keep the source DS representation verbatim"
    # behaviour. Numeric helpers below parse them when arithmetic is needed.
    def reference_image_orientation_str
      read_dicom(reference_dicoms.first).value("0020,0037").to_s
    end

    def reference_pixel_spacing_str
      read_dicom(reference_dicoms.first).value("0028,0030").to_s
    end

    def reference_slice_thickness_str
      read_dicom(reference_dicoms.first).value("0018,0050").to_s
    end

    def reference_slice_thickness
      reference_slice_thickness_str.to_f
    end

    def reference_rows
      read_dicom(reference_dicoms.first).value("0028,0010").to_i
    end

    def reference_columns
      read_dicom(reference_dicoms.first).value("0028,0011").to_i
    end

    def reference_frame_of_reference_uid
      read_dicom(reference_dicoms.first).value("0020,0052")
    end

    def reference_position_reference_indicator
      read_dicom(reference_dicoms.first).value("0020,1040")
    end

    def first_reference
      read_dicom(reference_dicoms.first)
    end

    def build_dataset
      d = DICOM::DObject.new
      add_file_meta(d)
      add_top_level(d)
      d
    end

    def add_file_meta(d)
      d.add(DICOM::Element.new("0002,0002", SEG_SOP_CLASS_UID))
      d.add(DICOM::Element.new("0002,0003", instance_uid))
      d.add(DICOM::Element.new("0002,0010", EXPLICIT_VR_LE_TS))
      # 0002,0000 (group length), 0002,0001 (version), 0002,0012 (impl class UID),
      # and 0002,0013 (impl version name) are written by the `dicom` gem at
      # serialization time. Implementation Class UID and Implementation Version
      # Name identify the writing toolkit, so they intentionally differ from
      # highdicom — see spec/element_diff_helper.rb for the allow-list.
    end

    def add_top_level(d)
      # 0008,0008 Image Type
      d.add(DICOM::Element.new("0008,0008", "DERIVED\\PRIMARY"))
      # 0008,0012 / 0008,0013 Instance Creation Date / Time
      d.add(DICOM::Element.new("0008,0012", content_date))
      d.add(DICOM::Element.new("0008,0013", content_time))
      # 0008,0016 / 0018 SOP Class / Instance UID
      d.add(DICOM::Element.new("0008,0016", SEG_SOP_CLASS_UID))
      d.add(DICOM::Element.new("0008,0018", instance_uid))

      copy_from_source(d, "0008,0020") # StudyDate
      d.add(DICOM::Element.new("0008,0023", content_date)) # ContentDate
      copy_from_source(d, "0008,0030") # StudyTime
      d.add(DICOM::Element.new("0008,0033", content_time)) # ContentTime
      copy_from_source(d, "0008,0050") # AccessionNumber
      d.add(DICOM::Element.new("0008,0060", "SEG"))
      d.add(DICOM::Element.new("0008,0070", manufacturer))
      copy_from_source(d, "0008,0090") # ReferringPhysicianName
      copy_from_source(d, "0008,1030") # StudyDescription
      d.add(DICOM::Element.new("0008,103E", series_description))
      d.add(DICOM::Element.new("0008,1090", manufacturer_model_name))

      add_referenced_series_sequence(d)
      add_source_image_sequence(d)

      # Patient module
      copy_from_source(d, "0010,0010") # PatientName
      copy_from_source(d, "0010,0020") # PatientID
      copy_from_source(d, "0010,0030") # PatientBirthDate
      copy_from_source(d, "0010,0040") # PatientSex
      copy_sequence_from_source(d, "0010,1002") # OtherPatientIDsSequence

      # Patient Study (optional)
      copy_from_source(d, "0010,1010") # PatientAge
      copy_from_source(d, "0010,1030") # PatientWeight
      copy_from_source(d, "0010,21B0") # AdditionalPatientHistory

      # Equipment
      d.add(DICOM::Element.new("0018,1000", device_serial_number))
      d.add(DICOM::Element.new("0018,1020", software_versions))

      # General Study / Series / FoR
      copy_from_source(d, "0020,000D") # StudyInstanceUID
      d.add(DICOM::Element.new("0020,000E", series_uid))
      copy_from_source(d, "0020,0010") # StudyID
      d.add(DICOM::Element.new("0020,0011", series_number.to_s))
      d.add(DICOM::Element.new("0020,0013", instance_number.to_s))
      d.add(DICOM::Element.new("0020,0052", reference_frame_of_reference_uid))
      copy_from_source(d, "0020,1040") # PositionReferenceIndicator

      add_dimension_organization_sequence(d)
      add_dimension_index_sequence(d)
      add_dimension_organization_type(d)

      # Image Pixel module
      d.add(DICOM::Element.new("0028,0002", 1))           # SamplesPerPixel
      d.add(DICOM::Element.new("0028,0004", "MONOCHROME2"))
      d.add(DICOM::Element.new("0028,0008", total_frames.to_s)) # NumberOfFrames (IS)
      d.add(DICOM::Element.new("0028,0010", reference_rows))
      d.add(DICOM::Element.new("0028,0011", reference_columns))
      d.add(DICOM::Element.new("0028,0100", 1))           # BitsAllocated
      d.add(DICOM::Element.new("0028,0101", 1))           # BitsStored
      d.add(DICOM::Element.new("0028,0102", 0))           # HighBit
      d.add(DICOM::Element.new("0028,0103", 0))           # PixelRepresentation
      d.add(DICOM::Element.new("0028,2110", "00"))        # LossyImageCompression

      # Segmentation Image
      d.add(DICOM::Element.new("0062,0001", "BINARY"))
      add_segment_sequence(d)
      # 0062,0013 SegmentsOverlap is missing from the `dicom` gem's dictionary,
      # so we set the VR explicitly to CS (per Part 6).
      d.add(DICOM::Element.new("0062,0013", "NO", vr: "CS", name: "Segments Overlap"))

      # Content Identification
      d.add(DICOM::Element.new("0070,0080", content_label))
      d.add(DICOM::Element.new("0070,0081", content_description))
      d.add(DICOM::Element.new("0070,0084", content_creator_name))

      add_shared_functional_groups_sequence(d)
      add_per_frame_functional_groups_sequence(d)
      add_pixel_data(d)
    end

    def copy_from_source(d, tag)
      el = first_reference[tag]
      return unless el
      d.add(DICOM::Element.new(tag, el.value))
    end

    def copy_sequence_from_source(d, tag)
      src_seq = first_reference[tag]
      return unless src_seq
      dst_seq = DICOM::Sequence.new(tag, parent: d)
      src_seq.items.each do |src_item|
        dst_item = DICOM::Item.new(parent: dst_seq)
        clone_into_item(src_item, dst_item)
      end
    end

    def clone_into_item(src, dst)
      src.elements.each do |el|
        if el.is_a?(DICOM::Sequence)
          sub_seq = DICOM::Sequence.new(el.tag, parent: dst)
          el.items.each do |sub_item|
            inner = DICOM::Item.new(parent: sub_seq)
            clone_into_item(sub_item, inner)
          end
        else
          DICOM::Element.new(el.tag, el.value, parent: dst)
        end
      end
    end

    def add_referenced_series_sequence(d)
      seq = DICOM::Sequence.new("0008,1115", parent: d)
      item = DICOM::Item.new(parent: seq)
      ref_inst_seq = DICOM::Sequence.new("0008,114A", parent: item)
      reference_slices.each do |slice|
        ri = DICOM::Item.new(parent: ref_inst_seq)
        DICOM::Element.new("0008,1150", slice[:sop_class_uid],    parent: ri)
        DICOM::Element.new("0008,1155", slice[:sop_instance_uid], parent: ri)
      end
      DICOM::Element.new("0020,000E", reference_series_uid, parent: item)
    end

    def add_source_image_sequence(d)
      seq = DICOM::Sequence.new("0008,2112", parent: d)
      reference_slices.each do |slice|
        item = DICOM::Item.new(parent: seq)
        DICOM::Element.new("0008,1150", slice[:sop_class_uid],    parent: item)
        DICOM::Element.new("0008,1155", slice[:sop_instance_uid], parent: item)
      end
    end

    def add_dimension_organization_sequence(d)
      seq = DICOM::Sequence.new("0020,9221", parent: d)
      item = DICOM::Item.new(parent: seq)
      DICOM::Element.new("0020,9164", dimension_organization_uid, parent: item)
    end

    # (0020,9311) Dimension Organization Type. Highdicom emits this when
    # there is a 3D spatial dimension (i.e. ≥2 reference slices) and sets it
    # to "3D" — match that behavior.
    def add_dimension_organization_type(d)
      return unless reference_slices.length >= 2
      d.add(DICOM::Element.new("0020,9311", "3D"))
    end

    def add_dimension_index_sequence(d)
      seq = DICOM::Sequence.new("0020,9222", parent: d)

      # Dimension 1: Referenced Segment Number (0062,000B in 0062,000A)
      i1 = DICOM::Item.new(parent: seq)
      DICOM::Element.new("0020,9164", dimension_organization_uid, parent: i1)
      _add_at(i1, "0020,9165", "0062,000B")
      _add_at(i1, "0020,9167", "0062,000A")
      DICOM::Element.new("0020,9421", "Segment Number", parent: i1)

      # Dimension 2: Image Position Patient (0020,0032 in 0020,9113)
      i2 = DICOM::Item.new(parent: seq)
      DICOM::Element.new("0020,9164", dimension_organization_uid, parent: i2)
      _add_at(i2, "0020,9165", "0020,0032")
      _add_at(i2, "0020,9167", "0020,9113")
      DICOM::Element.new("0020,9421", "Image Position Patient", parent: i2)
    end

    # AT (Attribute Tag) value: two little-endian uint16, packed as 4 bytes.
    # The `dicom` gem's Element.new(value=...) constructor re-encodes via
    # VALUE_CONVERSION, which mangles a 4-byte AT payload. We pass it as
    # :bin instead so the bytes are preserved verbatim.
    def _add_at(item, attr_tag, value_tag)
      group, elem = value_tag.split(",").map { |s| Integer(s, 16) }
      DICOM::Element.new(attr_tag, nil, bin: [group, elem].pack("v v"), parent: item)
    end

    def add_segment_sequence(d)
      seq = DICOM::Sequence.new("0062,0002", parent: d)
      item = DICOM::Item.new(parent: seq)

      # 0062,0003 Segmented Property Category Code Sequence
      cat_seq = DICOM::Sequence.new("0062,0003", parent: item)
      cat_item = DICOM::Item.new(parent: cat_seq)
      DICOM::Element.new("0008,0100", segment[:category][:code],    parent: cat_item)
      DICOM::Element.new("0008,0102", segment[:category][:scheme],  parent: cat_item)
      DICOM::Element.new("0008,0104", segment[:category][:meaning], parent: cat_item)

      DICOM::Element.new("0062,0004", 1,                    parent: item) # SegmentNumber
      DICOM::Element.new("0062,0005", segment[:label],      parent: item) # SegmentLabel
      DICOM::Element.new("0062,0008", segment_algo_type,    parent: item) # SegmentAlgorithmType

      if segment_algo_type != "MANUAL"
        algo_seq = DICOM::Sequence.new("0062,0007", parent: item)
        algo_item = DICOM::Item.new(parent: algo_seq)
        DICOM::Element.new("0008,0100", "113076",        parent: algo_item) # Code Value (DCM)
        DICOM::Element.new("0008,0102", "DCM",           parent: algo_item)
        DICOM::Element.new("0008,0104", "Segmentation",  parent: algo_item)
        DICOM::Element.new("0062,0009", segment.dig(:algorithm, :name)    || "", parent: item) # SegmentAlgorithmName
        DICOM::Element.new("0018,1020", segment.dig(:algorithm, :version) || "", parent: item)
      end

      # 0062,000F Segmented Property Type Code Sequence
      type_seq = DICOM::Sequence.new("0062,000F", parent: item)
      type_item = DICOM::Item.new(parent: type_seq)
      DICOM::Element.new("0008,0100", segment[:type][:code],    parent: type_item)
      DICOM::Element.new("0008,0102", segment[:type][:scheme],  parent: type_item)
      DICOM::Element.new("0008,0104", segment[:type][:meaning], parent: type_item)
    end

    def segment_algo_type
      (segment.dig(:algorithm, :type) || "MANUAL").to_s.upcase
    end

    def add_shared_functional_groups_sequence(d)
      seq = DICOM::Sequence.new("5200,9229", parent: d)
      item = DICOM::Item.new(parent: seq)

      # 0020,9116 Plane Orientation Sequence
      pos_seq = DICOM::Sequence.new("0020,9116", parent: item)
      pos_item = DICOM::Item.new(parent: pos_seq)
      DICOM::Element.new("0020,0037", reference_image_orientation_str, parent: pos_item)

      # 0028,9110 Pixel Measures Sequence
      pm_seq = DICOM::Sequence.new("0028,9110", parent: item)
      pm_item = DICOM::Item.new(parent: pm_seq)
      DICOM::Element.new("0018,0050", reference_slice_thickness_str, parent: pm_item)
      DICOM::Element.new("0018,0088", spacing_between_slices_str,    parent: pm_item)
      DICOM::Element.new("0028,0030", reference_pixel_spacing_str,   parent: pm_item)
    end

    # Use the source's SpacingBetweenSlices verbatim when present, so that the
    # pydicom DS round-tripping is preserved. When absent, fall back to
    # slice-thickness (single-frame) or computed-from-positions (multi-frame).
    def spacing_between_slices_str
      src = first_reference["0018,0088"]
      return src.value if src && src.value && src.value != ""
      return reference_slice_thickness_str if reference_slices.length < 2

      z1 = reference_slices[0][:image_position_patient][2]
      z2 = reference_slices[1][:image_position_patient][2]
      DS.format_value((z2 - z1).abs)
    end

    def add_per_frame_functional_groups_sequence(d)
      seq = DICOM::Sequence.new("5200,9230", parent: d)
      per_frame_items.each_with_index do |slice, sorted_index|
        item = DICOM::Item.new(parent: seq)

        # 0008,9124 Derivation Image Sequence
        deriv_seq = DICOM::Sequence.new("0008,9124", parent: item)
        deriv_item = DICOM::Item.new(parent: deriv_seq)
        src_img_seq = DICOM::Sequence.new("0008,2112", parent: deriv_item)
        src_item = DICOM::Item.new(parent: src_img_seq)
        DICOM::Element.new("0008,1150", slice[:sop_class_uid],    parent: src_item)
        DICOM::Element.new("0008,1155", slice[:sop_instance_uid], parent: src_item)
        DICOM::Element.new("0028,135A", "YES", parent: src_item) # SpatialLocationsPreserved
        purp_seq = DICOM::Sequence.new("0040,A170", parent: src_item)
        purp_item = DICOM::Item.new(parent: purp_seq)
        DICOM::Element.new("0008,0100", "121322", parent: purp_item)
        DICOM::Element.new("0008,0102", "DCM",    parent: purp_item)
        DICOM::Element.new("0008,0104", "Source image for image processing operation",
                           parent: purp_item)
        # Derivation Code Sequence
        deriv_code_seq = DICOM::Sequence.new("0008,9215", parent: deriv_item)
        dc_item = DICOM::Item.new(parent: deriv_code_seq)
        DICOM::Element.new("0008,0100", "113076",       parent: dc_item)
        DICOM::Element.new("0008,0102", "DCM",          parent: dc_item)
        DICOM::Element.new("0008,0104", "Segmentation", parent: dc_item)

        # 0020,9111 Frame Content Sequence
        fc_seq = DICOM::Sequence.new("0020,9111", parent: item)
        fc_item = DICOM::Item.new(parent: fc_seq)
        # DimensionIndexValues: VR=UL, [segment_number, sorted_frame_index_1_based].
        # The `dicom` gem's Element constructor parses backslash-separated UL
        # strings as a single scalar — so we set the raw little-endian bytes.
        DICOM::Element.new("0020,9157", nil,
                           bin: [1, sorted_index + 1].pack("V*"),
                           parent: fc_item)

        # 0020,9113 Plane Position Sequence
        pp_seq = DICOM::Sequence.new("0020,9113", parent: item)
        pp_item = DICOM::Item.new(parent: pp_seq)
        DICOM::Element.new("0020,0032",
                           slice[:image_position_patient].map { |v| DS.format_value(v) }.join("\\"),
                           parent: pp_item)

        # 0062,000A Segment Identification Sequence
        si_seq = DICOM::Sequence.new("0062,000A", parent: item)
        si_item = DICOM::Item.new(parent: si_seq)
        DICOM::Element.new("0062,000B", 1, parent: si_item) # ReferencedSegmentNumber
      end
    end

    def total_frames
      per_frame_items.length
    end

    def add_pixel_data(d)
      packed = DicomSeg::PixelPacking.pack_binary(mask: mask,
                                                  rows: reference_rows,
                                                  cols: reference_columns,
                                                  frame_order: per_frame_items.map { |s| s[:frame_index] })
      el = DICOM::Element.new("7FE0,0010", nil, bin: packed)
      d.add(el)
    end
  end
end
