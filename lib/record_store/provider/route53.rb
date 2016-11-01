require 'fog/aws'

module RecordStore
  class Provider::Route53 < Provider
    class << self
      def supports_alias?
        false
      end

      def add(record, zone)
        r = existing_or_new_record(zone, record.type, record.fqdn)
        r.ttl = record.ttl
        r.value = value_from_record(record)
        r.save
      end

      def remove(record, zone)
        existing_record(zone, record.type, record.fqdn).destroy
      end

      def update(id, record, zone)
        r = existing_record(zone, record.type, record.fqdn)
        r.ttl = record.ttl
        r.value = value_from_record(record)
        r.save
      end

      # returns an array of Record objects that match the records which exist in the provider
      def retrieve_current_records(zone:, stdout: $stdout)
        api_zone = session.zones.detect { |z| z.domain == zone + '.' }
        api_zone.records.map do |record_group|
          record_group.value.map do |record|
            begin
              build_from_api(record_group, record, zone)
            rescue StandardError
              stdout.puts "Cannot build record: #{record}"
              raise
            end
          end
        end.flatten.select(&:present?)
      end

      # Returns an array of the zones managed by provider as strings
      def zones
        session.zones.map(&:domain)
      end

      private

      def session
        @dns ||= Fog::DNS.new(session_params)
      end

      def session_params
        {
          provider: 'AWS',
          aws_access_key_id: secrets.fetch('access_key_id'),
          aws_secret_access_key: secrets.fetch('secret_access_key')
        }
      end

      def secrets
        super.fetch('route53')
      end

      def build_from_api(api_record, api_record_value, zone)
        record_type = api_record.type
        record = {
          record_id: api_record.name,
          ttl: api_record.ttl.to_i,
          fqdn: api_record.name,
        }

        return if record_type == 'SOA'

        case record_type
        when 'A', 'AAAA'
          record.merge!(address: api_record_value)
        when 'ALIAS'
          record.merge!(alias: api_record_value)
        when 'CNAME'
          record.merge!(cname: api_record_value)
        when 'MX'
          record.merge!(preference: api_record.prio, exchange: api_record_value)
        when 'NS'
          record.merge!(nsdname: api_record_value)
        when 'SPF', 'TXT'
          record.merge!(txtdata: api_record_value)
        when 'SRV'
          weight, port, host = api_record_value.split(' ')

          record.merge!(
            priority: api_record.fetch('prio').to_i,
            weight: weight.to_i,
            port: port.to_i,
            target: Record.ensure_ends_with_dot(host),
          )
        end

        unless record.fetch(:fqdn).ends_with?('.')
          record[:fqdn] += '.'
        end

        Record.const_get(record_type).new(record)
      end

      def existing_record(zone, record_type, fqdn)
        api_zone = session.zones.detect { |z| z.domain == zone + '.' }
        api_zone.records.get(fqdn, record_type)
      end

      def existing_or_new_record(zone, record_type, fqdn)
        api_record = existing_record(zone, record_type, fqdn)
        api_record ||= api_zone.records.new(type: record_type, name: fqdn)
        api_record
      end

      def value_from_record(record)
        case record.type
        when 'A', 'AAAA'
          return record.address
        when 'ALIAS'
          return record.alias.chomp('.')
        when 'CNAME'
          return record.cname.chomp('.')
        when 'MX'
          return "#{record.preference} #{record.exchange.chomp('.')}"
        when 'NS'
          return record.nsdname.chomp('.')
        when 'SPF', 'TXT'
          return record.txtdata
        when 'SRV'
          return "#{record.priority} #{record.weight} #{record.port} #{record.target.chomp('.')}"
        end

        raise NotImplementedError("Record type #{record.type} is not implemented in the Route53 provider.")
      end
    end
  end
end
