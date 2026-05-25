module DicomSeg
  # Pack a binary 3-D mask into the DICOM SEG packed-bits PixelData format.
  #
  # DICOM Bits Allocated = 1 packs voxels in row-major order, 8 voxels per byte,
  # LSB-first within each byte (i.e. the first pixel of a row is bit 0 of the
  # first byte). Frames are concatenated in `frame_order`, each frame padded
  # to a byte boundary at the end of its last row (highdicom's convention is
  # to pad only the very end of the *concatenated* bit stream, not per frame —
  # but for binary segmentations with rows*cols a multiple of 8 the result is
  # the same).
  module PixelPacking
    module_function

    # mask[k][j][i] is the voxel at frame k, row j, col i. Values truthy/non-zero
    # are encoded as 1, else 0.
    def pack_binary(mask:, rows:, cols:, frame_order:)
      bit_count = frame_order.length * rows * cols
      byte_count = (bit_count + 7) / 8
      buf = "\x00".b * byte_count

      bit_index = 0
      frame_order.each do |k|
        frame = mask[k]
        rows.times do |j|
          row = frame[j]
          cols.times do |i|
            v = row[i]
            if v && v.to_i != 0
              byte_idx = bit_index >> 3
              bit_pos  = bit_index & 7
              buf.setbyte(byte_idx, buf.getbyte(byte_idx) | (1 << bit_pos))
            end
            bit_index += 1
          end
        end
      end

      # Ensure even length (OB byte stream must be even).
      buf << "\x00".b if buf.bytesize.odd?
      buf
    end
  end
end
