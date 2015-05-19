require 'aws-sdk'

class Hq

  @@state = nil
  @@general = nil
  @@control = nil
  @@command = nil
  @@options = {}
  @@hives = []
  @@region = 'us-east-1'
  @@username = nil
  @@key_name = nil

  STATE_FILE = File.expand_path('~/.hives')

  def initialize(command, options={})
    @@command = command
    @@options = options
    @@state = readServerList
    if @@state and @@state.has_key? :region
      @@username = @@state[:username]
      @@key_name = @@state[:key_name]
      @@region = @@state[:region]
      @@hives = @@state[:instances]
      @@image_id = @@state[:image_id]
    end
    @@region = options.has_key?(:region) ? options[:region] : @@region

    Aws.config.update({:region => @@region})
    @@general = Aws::EC2::Resource.new
    @@control = Aws::EC2::Client.new
  end

  def dispatch
    case @@command
    when 'up'
      createHives @@options
    when 'attack'
      hivesAttack @@options
    when 'scale'
      scaleHives @@options
    when 'down'
      destroyHives
    end
  end

  def scaleHives(options)
    if @@state.nil?
      abort 'Perhaps build some hives first?'
    end
    number_of_hive = options.has_key?(:number) ? options[:number].to_i : 1
    if @@hives.count == number_of_hive
      abort 'No hives scaled'
    elsif @@hives.count > number_of_hive
      destroyHives number_of_hive > 0 ? @@hives[number_of_hive..-1] : {}
    else
      options = {:number => number_of_hive - @@hives.count, :username => @@username, :region => @@region, :key_name => @@key_name, :image_id => @@image_id}
      createHives options
    end
  end

  def hiveAttack(options)
  end

  # create a number of hives using user options
  def createHives(options)
    number_of_hive = options.has_key?(:number) ? options[:number].to_i : 1
    hive_options = {
      :key_name      => nil,
      :image_id      => nil,
      :min_count     => number_of_hive,
      :max_count     => number_of_hive,
      :instance_type => 't1.micro'
    }
    hive_options.merge!(options.select {|k,v| hive_options.has_key?(k)})
    hives = @@general.create_instances hive_options
    puts "%i hives are being built" % number_of_hive
    writeServerList options[:username], options[:key_name], options[:region], options[:image_id], hives.map(&:id) + @@hives
    checkHivesStatus hives
    @@general.create_tags({:tags => [{:key => 'Name', :value => 'hive'}], :resources => hives.map(&:id)})
  end

  # tear down all running hives
  def destroyHives instances = []
    instances = instances.empty? ? @@hives : instances
    if not instances.empty?
      @@control.terminate_instances instance_ids: instances
      if instances.count == @@hives.count
        removeServerList
      else
        writeServerList @@username, @@key_name, @@region, @@image_id, @@hives.reject {|item| instances.include? item}
      end
    else
      abord 'Perhaps build some hives first?'
    end
    puts '%i hives are teared down!' % instances.count
  end

  private

  def readServerList
    if not ::File.exist? STATE_FILE
      return false
    end
    server_state = ::IO.readlines(STATE_FILE).map! {|l| l.strip}
    {:username => server_state[0], :key_name => server_state[1], :region => server_state[2], :image_id => server_state[3], :instances => server_state[4..-1]}
  end

  def writeServerList(username, key, region, image_id, instances)
    ::File.open(STATE_FILE, 'w') do |f|
      f.write("%s\n" % username)
      f.write("%s\n" % key)
      f.write("%s\n" % region)
      f.write("%s\n" % image_id)
      f.write(instances.join("\n"))
    end
  end

  def removeServerList
    ::File.delete STATE_FILE
  end

  # check over status of hives
  def checkHivesStatus(hives)
    hives_built = []
    filters = [{:name => 'instance-state-name', :values => ['pending', 'running']}]
    while hives_built.count != hives.count do
      statuses = @@control.describe_instance_status instance_ids: hives.map(&:id), include_all_instances: true, filters: filters
      statuses.each do |response|
        response[:instance_statuses].each do |instance|
          building = instance[:instance_state].name == 'running' ? false : true
          instance_id = instance[:instance_id]
          if not building and not hives_built.include? instance_id
            puts 'Hive %s is ready!' % instance_id
            hives_built << instance_id
          end
        end
      end
      sleep(1)
    end
  end

end
