module Delayed
  class PerformableMethod < Struct.new(:object, :method_name, :args)
    CLASS_STRING_FORMAT = /^CLASS\:([A-Z][\w\:]+)$/
    AR_STRING_FORMAT    = /^AR\:([A-Z][\w\:]+)\:(\d+)$/

    def initialize(object, method_name, args)
      raise NoMethodError, "undefined method `#{method_name}' for #{self.inspect}" unless object.respond_to?(method_name)

      self.object = dump(object)
      self.args   = args.map { |a| dump(a) }
      self.method_name = method_name.to_sym
    end

    def display_name
      case self.object
      when CLASS_STRING_FORMAT then "#{$1}.#{method_name}"
      when AR_STRING_FORMAT    then "#{$1}##{method_name}"
      else "Unknown##{method_name}"
      end
    end

    def perform
      load(object).send(method_name, *args.map{|a| load(a)})
    rescue ActiveRecord::RecordNotFound
      # We cannot do anything about objects which were deleted in the meantime
      true
    end

    private

    def load(arg)
      case arg
      when CLASS_STRING_FORMAT then $1.constantize
      when AR_STRING_FORMAT    then $1.constantize.find($2)
      else arg
      end
    end

    def dump(arg)
      case arg
      when Class              then class_to_string(arg)
      when ActiveRecord::Base then ar_to_string(arg)
      else arg
      end
    end

    def ar_to_string(obj)
      "AR:#{obj.class}:#{obj.id}"
    end

    def class_to_string(obj)
      "CLASS:#{obj.name}"
    end
  end
end