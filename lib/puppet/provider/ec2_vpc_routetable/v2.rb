require_relative '../../../puppet_x/puppetlabs/aws.rb'

Puppet::Type.type(:ec2_vpc_routetable).provide(:v2, :parent => PuppetX::Puppetlabs::Aws) do
  confine feature: :aws
  confine feature: :retries

  mk_resource_methods
  remove_method :tags=

  def self.instances
    regions.collect do |region|
      begin
        response = ec2_client(region).describe_route_tables()
        tables = []
        response.data.route_tables.each do |table|
          hash = route_table_to_hash(region, table)
          tables << new(hash) if has_name?(hash)
        end
        tables
      rescue StandardError => e
        raise PuppetX::Puppetlabs::FetchingAWSDataError.new(region, self.resource_type.name.to_s, e.message)
      end
    end.flatten
  end

  read_only(:region, :vpc, :routes)

  def self.prefetch(resources)
    instances.each do |prov|
      if resource = resources[prov.name] # rubocop:disable Lint/AssignmentInCondition
        resource.provider = prov if resource[:region] == prov.region
      end
    end
  end

  def self.route_to_hash(region, route)
    target_id = if !route.gateway_id.nil?
      route.gateway_id
    elsif !route.vpc_peering_connection_id.nil?
      route.vpc_peering_connection_id
    elsif !route.network_interface_id.nil?
      route.network_interface_id
    else
      nil
    end
    gateway_name = route.state == 'active' ? gateway_name_from_id(region, target_id) : nil
    hash = {
      'destination_cidr_block' => route.destination_cidr_block,
      'gateway' => gateway_name,
    }
    gateway_name.nil? ? nil : hash
  end

  def self.route_table_to_hash(region, table)
    name = name_from_tag(table)
    return {} unless name
    routes = table.routes.collect do |route|
      route_to_hash(region, route)
    end.compact
    {
      name: name,
      id: table.route_table_id,
      vpc: vpc_name_from_id(region, table.vpc_id),
      ensure: :present,
      routes: routes,
      region: region,
      tags: tags_for(table),
    }
  end

  def exists?
    Puppet.info("Checking if Route table #{name} exists in #{target_region}")
    @property_hash[:ensure] == :present
  end

  def create
    Puppet.info("Creating Route table #{name} in #{target_region}")
    ec2 = ec2_client(target_region)

    routes = resource[:routes]
    routes = [routes] unless routes.is_a?(Array)

    vpc_response = ec2.describe_vpcs(filters: [
      {name: "tag:Name", values: [resource[:vpc]]},
    ])
    fail "Multiple VPCs with name #{resource[:vpc]}" if vpc_response.data.vpcs.count > 1
    fail "No VPCs with name #{resource[:vpc]}" if vpc_response.data.vpcs.empty?

    response = ec2.create_route_table(
      vpc_id: vpc_response.data.vpcs.first.vpc_id,
    )
    id = response.data.route_table.route_table_id
    with_retries(:max_tries => 5) do
      ec2.create_tags(
        resources: [id],
        tags: tags_for_resource,
      )
    end
    routes.each do |route|
      internet_gateway_response = ec2.describe_internet_gateways(filters: [
        {name: 'tag:Name', values: [route['gateway']]},
      ])
      found_internet_gateway = !internet_gateway_response.data.internet_gateways.empty?

      unless found_internet_gateway
        vpn_gateway_response = ec2.describe_vpn_gateways(filters: [
          {name: 'tag:Name', values: [route['gateway']]},
        ])
        found_vpn_gateway = !vpn_gateway_response.data.vpn_gateways.empty?
      end

      unless found_internet_gateway || found_vpn_gateway
        peering_connection_response = ec2.describe_vpc_peering_connections(filters: [
        {name: 'tag:Name', values: [route['gateway']]},
      ])
        found_peering_connection = !peering_connection_response.data.vpc_peering_connections.empty?
      end

      unless found_internet_gateway || found_vpn_gateway || found_peering_connection
        instances_response = ec2.describe_instances(filters: [
        {name: 'instance-state-name', values: ['pending', 'running', 'stopping', 'stopped']},
        {name: 'tag:Name', values: [route['gateway']]}])
        found_network_interface = !instances_response.data.reservations.empty?
      end

      if found_internet_gateway 
        int_gw_id = internet_gateway_response.data.internet_gateways.first.internet_gateway_id
        ec2.create_route(
        route_table_id: id,
        destination_cidr_block: route['destination_cidr_block'],
        gateway_id: int_gw_id
        )
      elsif found_vpn_gateway 
        vpn_fgw_id = vpn_gateway_response.data.vpn_gateways.first.vpn_gateway_id
        ec2.create_route(
        route_table_id: id,
        destination_cidr_block: route['destination_cidr_block'],
        gateway_id: vpn_fgw_id,
        )
      elsif found_peering_connection
        peer_id = peering_connection_response.data.vpc_peering_connections.first.vpc_peering_connection_id
        ec2.create_route(
        route_table_id: id,
        destination_cidr_block: route['destination_cidr_block'],
        vpc_peering_connection_id: peer_id,
        )
      elsif found_network_interface
        if_id = instances_response.data.reservations.first.instances.first.network_interfaces.first.network_interface_id
        ec2.create_route(
        route_table_id: id,
        destination_cidr_block: route['destination_cidr_block'],
        network_interface_id: if_id
        )
      else
        nil
      end
    end
    @property_hash[:ensure] = :present
  end

  def destroy
    Puppet.info("Deleting Route table #{name} in #{target_region}")
    ec2_client(target_region).delete_route_table(route_table_id: @property_hash[:id])
    @property_hash[:ensure] = :absent
  end
end
