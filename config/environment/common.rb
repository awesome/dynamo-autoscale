require 'logger'
require 'fileutils'
require 'time'
require 'csv'
require 'tempfile'
require 'aws-sdk'
require 'active_support/all'
require 'rbtree'
require 'colored'
require 'pp'
require 'erb'
require 'pony'

require_relative '../../lib/dynamo-autoscale/logger'
require_relative '../../lib/dynamo-autoscale/poller'
require_relative '../../lib/dynamo-autoscale/actioner'

module DynamoAutoscale
  include DynamoAutoscale::Logger

  DEFAULT_AWS_REGION = 'us-east-1'

  def self.root
    File.expand_path(File.join(File.dirname(__FILE__), '..', '..'))
  end

  def self.data_dir
    File.join(self.root, 'data')
  end

  def self.config
    @@config ||= {}
  end

  def self.config= new_config
    @@config = new_config
  end

  def self.setup_from_config path, overrides = {}
    logger.debug "[setup] Loading config..."
    self.config = YAML.load_file(path).merge(overrides)

    if config[:tables].nil? or config[:tables].empty?
      STDERR.puts "You need to specify at least one table in your config's " +
        ":tables section."

      exit 1
    end

    filters = config[:dry_run] ? DynamoAutoscale::LocalActioner.faux_provisioning_filters : []
    if filters.empty?
      logger.debug "[setup] Not running as a dry run. Hitting production Dynamo."
    else
      logger.debug "[setup] Running as dry run. No throughputs will be changed."
    end

    DynamoAutoscale.poller_opts = {
      tables: config[:tables],
      filters: filters,
    }

    logger.debug "[setup] Poller options are: #{DynamoAutoscale.poller_opts}"

    DynamoAutoscale.actioner_opts = {
      group_downscales: config[:group_downscales],
      flush_after: config[:flush_after],
    }

    logger.debug "[setup] Actioner options are: #{DynamoAutoscale.actioner_opts}"

    if config[:minimum_throughput]
      DynamoAutoscale::Actioner.minimum_throughput = config[:minimum_throughput]
    end

    if config[:maximum_throughput]
      DynamoAutoscale::Actioner.maximum_throughput = config[:maximum_throughput]
    end

    logger.debug "[setup] Minimum throughput set to: " +
      "#{DynamoAutoscale::Actioner.minimum_throughput}"
    logger.debug "[setup] Maximum throughput set to: " +
      "#{DynamoAutoscale::Actioner.maximum_throughput}"

    logger.debug "[setup] Ruleset loading from: #{config[:ruleset]}"
    DynamoAutoscale.ruleset_location = config[:ruleset]

    logger.debug "[setup] Loaded #{DynamoAutoscale.rules.rules.values.flatten.count} rules."

    DynamoAutoscale.load_services
  end

  def self.require_all path
    Dir[File.join(root, path, '*.rb')].each { |file| require file }
  end

  def self.load_services
    Dir[File.join(DynamoAutoscale.root, 'config', 'services', '*.rb')].each do |path|
      load path
    end
  end

  def self.dispatcher= new_dispatcher
    @@dispatcher = new_dispatcher
  end

  def self.dispatcher
    @@dispatcher ||= Dispatcher.new
  end

  def self.poller_opts= new_poller_opts
    @@poller_opts = new_poller_opts
  end

  def self.poller_opts
    @@poller_opts ||= {}
  end

  def self.poller_class= new_poller_class
    @@poller_class = new_poller_class
  end

  def self.poller_class
    @@poller_class ||= LocalDataPoll
  end

  def self.poller= new_poller
    @@poller = new_poller
  end

  def self.poller
    @@poller ||= poller_class.new(poller_opts)
  end

  def self.actioner_class= klass
    @@actioner_class = klass
  end

  def self.actioner_class
    @@actioner_class ||= LocalActioner
  end

  def self.actioner_opts= new_opts
    @@actioner_opts = new_opts
  end

  def self.actioner_opts
    @@actioner_opts ||= {}
  end

  def self.actioners
    @@actioners ||= Hash.new do |h, k|
      h[k] = actioner_class.new(k, actioner_opts)
    end
  end

  def self.reset_tables
    @@tables = Hash.new { |h, k| h[k] = TableTracker.new(k) }
  end

  def self.tables
    @@tables ||= Hash.new { |h, k| h[k] = TableTracker.new(k) }
  end

  def self.ruleset_location
    @@ruleset_location ||= nil
  end

  def self.ruleset_location= new_ruleset_location
    @@ruleset_location = new_ruleset_location
  end

  def self.rules
    @@rules ||= RuleSet.new(ruleset_location)
  end

  def self.current_table= new_current_table
    @@current_table = new_current_table
  end

  def self.current_table
    @@current_table ||= nil
  end
end

DynamoAutoscale.require_all 'lib/dynamo-autoscale'
DynamoAutoscale.require_all 'lib/dynamo-autoscale/ext/**'

DynamoAutoscale.load_services
