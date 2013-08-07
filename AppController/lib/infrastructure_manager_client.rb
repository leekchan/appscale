#!/usr/bin/ruby -w
# Programmer: Chris Bunch


# Imports within Ruby's standard libraries
require 'openssl'
require 'soap/rpc/driver'
require 'timeout'


# Imports for the AppController
$:.unshift File.join(File.dirname(__FILE__), "..")
require 'djinn'


# Imports for AppController libraries
$:.unshift File.join(File.dirname(__FILE__))
require 'helperfunctions'


class InfrastructureManagerClient


  # The port that the InfrastructureManager runs on, by default.
  SERVER_PORT = 17444


  # A constant that indicates that there should be no timeout on SOAP calls.
  NO_TIMEOUT = -1


  # A constant that callers can use to indicate that SOAP calls should be
  # retried if they fail (e.g., if the connection was refused).
  RETRY_ON_FAIL = true


  # A constant that callers can use to indicate that SOAP calls should not
  # be retried if they fail.
  ABORT_ON_FAIL = false


  # The SOAP client that we use to communicate with the InfrastructureManager.
  attr_accessor :conn


  # The secret string that is used to authenticate this client with
  # InfrastructureManagers. It is initially generated by 
  # appscale-run-instances and can be found on the machine that ran that tool,
  # or on any AppScale machine.
  attr_accessor :secret


  def initialize(secret)
    ip = HelperFunctions.local_ip()
    @secret = secret
    
    @conn = SOAP::RPC::Driver.new("https://#{ip}:#{SERVER_PORT}")
    @conn.add_method("get_queues_in_use", "secret")
    @conn.add_method("run_instances", "parameters", "secret")
    @conn.add_method("describe_instances", "parameters", "secret")
    @conn.add_method("terminate_instances", "parameters", "secret")
    @conn.add_method("attach_disk", "parameters", "disk_name", "instance_id",
      "secret")
  end
  

  # A helper method that makes SOAP calls for us. This method is mainly here to
  # reduce code duplication: all SOAP calls expect a certain timeout and can
  # tolerate certain exceptions, so we consolidate this code into this method.
  # Here, the caller specifies the timeout for the SOAP call (or NO_TIMEOUT
  # if an infinite timeout is required) as well as whether the call should
  # be retried in the face of exceptions. Exceptions can occur if the machine
  # is not yet running or is too busy to handle the request, so these exceptions
  # are automatically retried regardless of the retry value. Typically
  # callers set this to false to catch 'Connection Refused' exceptions or
  # the like. Finally, the caller must provide a block of
  # code that indicates the SOAP call to make: this is really all that differs
  # between the calling methods. The result of the block is returned to the
  # caller. 
  def make_call(time, retry_on_except, callr, ok_to_fail=false)
    refused_count = 0
    max = 5

    begin
      Timeout::timeout(time) {
        yield if block_given?
      }
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH => except
      Djinn.log_warn("Saw an Exception of class #{except.class}")
      if refused_count > max
        return false if ok_to_fail
        Djinn.log_fatal("Connection refused. Is the AppController running?")
        raise AppScaleException.new("Connection was refused. Is the " +
          "AppController running?")
      else
        refused_count += 1
        Kernel.sleep(1)
        retry
      end
    rescue Timeout::Error
      Djinn.log_warn("Saw a Timeout Error")
      return false if ok_to_fail
      retry
    rescue OpenSSL::SSL::SSLError, NotImplementedError, Errno::EPIPE, Errno::ECONNRESET => except
      Djinn.log_warn("Saw an Exception of class #{except.class}")
      Kernel.sleep(1)
      retry
    rescue Exception => except
      newline = "\n"
      Djinn.log_warn("Saw an Exception of class #{except.class}")
      Djinn.log_warn("#{except.backtrace.join(newline)}")

      if retry_on_except
        Kernel.sleep(1)
        retry
      else
        Djinn.log_fatal("Couldn't recover from a #{except.class} Exception, " +
          "with message: #{except}")
        raise AppScaleException.new("[#{callr}] We saw an unexpected error of" +
          " the type #{except.class} with the following message:\n#{except}.")
      end
    end
  end


  # Parses the credentials that AppControllers store and constructs a
  # Hash containing infrastructure-specific parameters.
  #
  # Args:
  #   creds: A Hash that contains all of the credentials passed between
  #     AppControllers.
  # Returns:
  #   A Hash that contains only the parameters needed to interact with AWS,
  #   Eucalyptus, or GCE.
  def get_parameters_from_credentials(creds)
    return {
      "credentials" => {
        # EC2 / Eucalyptus-specific credentials
        'EC2_ACCESS_KEY' => creds['ec2_access_key'],
        'EC2_SECRET_KEY' => creds['ec2_secret_key'],
        'EC2_URL' => creds['ec2_url']
      },
      'project' => creds['project'],  # GCE-specific
      "group" => creds['group'],
      "image_id" => creds['machine'],
      "infrastructure" => creds['infrastructure'],
      "instance_type" => creds['instance_type'],
      "keyname" => creds['keyname'],
      "use_spot_instances" => creds['use_spot_instances'],
      "max_spot_price" => creds['max_spot_price']
    }
  end


  def run_instances(parameters)
    obscured = parameters.dup
    obscured['credentials'] = HelperFunctions.obscure_creds(obscured['credentials'])
    Djinn.log_debug("Calling run_instances with parameters " +
      "#{obscured.inspect}")

    make_call(NO_TIMEOUT, RETRY_ON_FAIL, "run_instances") { 
      @conn.run_instances(parameters.to_json, @secret)
    }
  end

  
  def describe_instances(parameters)
    Djinn.log_debug("Calling describe_instances with parameters " +
      "#{parameters.inspect}")

    make_call(NO_TIMEOUT, RETRY_ON_FAIL, "describe_instances") { 
      @conn.describe_instances(parameters.to_json, @secret)
    }
  end


  def terminate_instances(creds, instance_ids)
    parameters = get_parameters_from_credentials(creds)

    if instance_ids.class != Array
      instance_ids = [instance_ids]
    end
    parameters['instance_ids'] = instance_ids

    terminate_result = make_call(NO_TIMEOUT, RETRY_ON_FAIL,
      "terminate_instances") {
      @conn.terminate_instances(parameters.to_json, @secret)
    }
    Djinn.log_debug("Terminate instances says [#{terminate_result}]")
  end
 
  
  def spawn_vms(num_vms, creds, job, disks)
    parameters = get_parameters_from_credentials(creds)
    parameters['num_vms'] = num_vms.to_s
    parameters['cloud'] = 'cloud1'

    run_result = run_instances(parameters)
    Djinn.log_debug("[IM] Run instances info says [#{run_result}]")
    reservation_id = run_result['reservation_id']

    vm_info = {}
    loop {
      describe_result = describe_instances("reservation_id" => reservation_id)
      Djinn.log_debug("[IM] Describe instances info says [#{describe_result}]")

      if describe_result["state"] == "running"
        vm_info = describe_result["vm_info"]
        break
      elsif describe_result["state"] == "failed"
        raise AppScaleException.new(describe_result["reason"])
      end
      Kernel.sleep(10)
    }

    # now, turn this info back into the format we normally use
    jobs = []
    if job.is_a?(String)
      # We only got one job, so just repeat it for each one of the nodes
      jobs = Array.new(size=vm_info['public_ips'].length, obj=job)
    else
      jobs = job
    end
    
    # ip:job:instance-id
    instances_created = []
    vm_info['public_ips'].each_index { |index|
      instances_created << {
        'public_ip' => vm_info['public_ips'][index],
        'private_ip' => vm_info['private_ips'][index],
        'jobs' => jobs[index],
        'instance_id' => vm_info['instance_ids'][index],
        'disk' => disks[index]
      }
    }

    return instances_created
  end


  # Asks the InfrastructureManager to attach a persistent disk to this machine.
  #
  # Args:
  #   parameters: A Hash that contains the credentials necessary to interact
  #     with the underlying cloud infrastructure.
  #   disk_name: A String that names the persistent disk to attach to this
  #     machine.
  #   instance_id: A String that names this machine's instance id, needed to
  #     tell the InfrastructureManager which machine to attach the persistent
  #     disk to.
  # Returns:
  #   The location on the local filesystem where the persistent disk was
  #   attached to.
  def attach_disk(credentials, disk_name, instance_id)
    parameters = get_parameters_from_credentials(credentials)
    Djinn.log_debug("Calling attach_disk with parameters " +
      "#{parameters.inspect}, with disk name #{disk_name} and instance id " +
      "#{instance_id}")

    make_call(NO_TIMEOUT, RETRY_ON_FAIL, "attach_disk") {
      return @conn.attach_disk(parameters.to_json, disk_name, instance_id,
        @secret)['location']
    }
  end


end
