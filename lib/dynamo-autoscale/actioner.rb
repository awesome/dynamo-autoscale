module DynamoAutoscale
  class Actioner
    include DynamoAutoscale::Logger

    attr_accessor :table, :upscales, :downscales

    def initialize table, opts = {}
      @table            = table
      @downscales       = 0
      @upscales         = 0
      @provisioned      = { reads: RBTree.new, writes: RBTree.new }
      @pending          = { reads: nil, writes: nil }
      @last_action      = nil
      @last_scale_check = Time.now.utc
      @downscale_warn   = false
      @opts             = opts
    end

    def provisioned_for metric
      @provisioned[normalize_metric(metric)]
    end

    def provisioned_writes
      @provisioned[:writes]
    end

    def provisioned_reads
      @provisioned[:reads]
    end

    def check_day_reset!
      now = Time.now.utc

      if now >= (check = (@last_scale_check + 1.day).midnight)
        logger.info "[scales] New day! Reset scaling counts back to 0."
        logger.debug "[scales] now: #{now}, comp: #{check}"

        if @downscales < 4
          logger.warn "[scales] Unused downscales. Used: #{@downscales}"
        end

        @upscales   = 0
        @downscales = 0
        @downscale_warn    = false
      end

      @last_scale_check = now
    end

    def upscales
      check_day_reset!
      @upscales
    end

    def downscales new_val = nil
      check_day_reset!
      @downscales
    end

    def set metric, to
      check_day_reset!

      from   = table.last_provisioned_for(metric)
      metric = normalize_metric(metric)

      if from == to
        logger.debug "Attempted to scale to same value. Ignoring..."
        return false
      end

      if from and from > to
        downscale metric, from, to
      else
        upscale metric, from, to
      end
    end

    def upscale metric, from, to
      if from and to > (from * 2)
        to = from * 2

        logger.warn "[#{metric.to_s.ljust(6)}] Attempted to scale up " +
          "more than allowed. Capped scale to #{to}."
      end

      logger.info "[#{metric.to_s.ljust(6)}][scaling #{"up".blue}] " +
        "#{from ? from.round(2) : "Unknown"} -> #{to.round(2)}"


      # Because upscales are not limited, we don't need to queue this operation.
      if result = scale(metric, to)
        @provisioned[metric][Time.now.utc] = to
        @upscales += 1
      end

      return result
    end

    def downscale metric, from, to
      if @downscales >= 4
        unless @downscale_warn
          @downscale_warn = true
          logger.warn "[#{metric.to_s.ljust(6)}][scaling #{"failed".red}]" +
            " Hit upper limit of downward scales per day."
        end

        return false
      end

      if @pending[metric]
        previous_pending = @pending[metric].last
        logger.info "[#{metric.to_s.ljust(6)}][scaling #{"down".blue}] " +
          "#{previous_pending} -> #{to.round(2)} (overwritten pending)"
      else
        logger.info "[#{metric.to_s.ljust(6)}][scaling #{"down".blue}] " +
          "#{from ? from.round(2) : "Unknown"} -> #{to.round(2)}"
      end

      queue_operation! metric, to

      if @opts[:group_downscales].nil? or should_flush?
        if flush_operations!
          @downscales += 1
          @last_action = Time.now.utc
          return true
        else
          return false
        end
      else
        return false
      end
    end

    def queue_operation! metric, value
      time = Time.now.utc

      case metric
      when :writes
        if @pending[:writes]
          logger.debug "Overwriting existing pending write with [" +
            "#{metric.inspect}, #{table.name}, #{value}]"
        end

        @pending[:writes] = [time, value]
      when :reads
        if @pending[:reads]
          logger.debug "Overwriting existing pending read with [" +
            "#{metric.inspect}, #{table.name}, #{value}]"
        end

        @pending[:reads] = [time, value]
      end
    end

    def flush_operations!
      result = nil

      if @pending[:writes] and @pending[:reads]
        wtime, wvalue = @pending[:writes]
        rtime, rvalue = @pending[:reads]

        if result = scale_both(rvalue, wvalue)
          @provisioned[:writes][wtime] = wvalue
          @provisioned[:reads][rtime] = rvalue

          @pending[:writes] = nil
          @pending[:reads] = nil
        end
      elsif @pending[:writes]
        time, value = @pending[:writes]

        if result = scale(:writes, value)
          @provisioned[:writes][time] = value

          @pending[:writes] = nil
        end
      elsif @pending[:reads]
        time, value = @pending[:reads]

        if result = scale(:reads, value)
          @provisioned[:reads][time] = value
          @pending[:reads] = nil
        end
      end

      return result
    end

    def should_flush?
      return true if (@pending[:reads] and @pending[:writes])
      return true if (@opts[:flush_after] and @last_action and
                     (Time.now.utc > @last_action + @opts[:flush_after]))
      return false
    end

    private

    def normalize_metric metric
      case metric
      when :reads, :provisioned_reads, :consumed_reads
        :reads
      when :writes, :provisioned_writes, :consumed_writes
        :writes
      end
    end
  end
end
