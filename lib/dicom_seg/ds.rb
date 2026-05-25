module DicomSeg
  # Decimal String (DS) formatting that matches pydicom's `format_number_as_ds`.
  #
  # DICOM DS is limited to 16 chars. pydicom packs as much precision as it can
  # into those 16 chars. To stay byte-identical with highdicom output we
  # replicate that exact algorithm.
  module DS
    module_function

    def format_value(val)
      raise TypeError, "DS value must be numeric, got #{val.class}" unless val.is_a?(Numeric)
      raise ArgumentError, "DS value must be finite, got #{val}" if val.respond_to?(:finite?) && !val.finite?

      f = val.to_f
      str = python_repr(f)
      return str if str.length <= 16

      sign_chars = f < 0 ? 1 : 0
      logval = Math.log10(f.abs)
      use_scientific = logval < -4 || logval >= (14 - sign_chars)

      if use_scientific
        remaining = 10 - sign_chars
        trunc = format_scientific(f, remaining)
        trunc = format_scientific(f, remaining - 1) if trunc.length > 16
        trunc
      elsif logval >= 1.0
        remaining = 14 - sign_chars - logval.floor.to_i
        Kernel.format("%.#{remaining}f", f)
      else
        remaining = 14 - sign_chars
        Kernel.format("%.#{remaining}f", f)
      end
    end

    # Match Python's repr(float). Python uses the shortest decimal that
    # round-trips, same as Ruby's Float#to_s — but scientific notation differs:
    # Python "1e-05", Ruby "1.0e-05". Normalize to Python form so the "fits in
    # 16 chars" branch produces identical bytes.
    def python_repr(f)
      s = f.to_s
      return s unless s.include?("e")

      mantissa, exp = s.split("e")
      exp_int = exp.to_i
      mantissa = mantissa.sub(/\.0\z/, "")
      sign = exp_int.negative? ? "-" : "+"
      "#{mantissa}e#{sign}#{exp_int.abs.to_s.rjust(2, "0")}"
    end

    def format_scientific(f, remaining)
      mantissa, exp = (Kernel.format("%.#{remaining}e", f)).split("e")
      exp_int = exp.to_i
      sign = exp_int.negative? ? "-" : "+"
      "#{mantissa}e#{sign}#{exp_int.abs.to_s.rjust(2, "0")}"
    end
  end
end
