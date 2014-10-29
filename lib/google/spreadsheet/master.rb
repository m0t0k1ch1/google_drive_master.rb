require 'logger'
require 'google/spreadsheet/master/version'
require 'google_drive/alias'

module Google
  module Spreadsheet
    module Master
      APPLICATION_NAME       = 'master'
      TOKEN_CREDENTIAL_URI   = 'https://accounts.google.com/o/oauth2/token'
      AUDIENCE               = 'https://accounts.google.com/o/oauth2/token'
      SCOPE                  = 'https://www.googleapis.com/auth/drive https://spreadsheets.google.com/feeds https://docs.google.com/feeds'
      INDEX_WS_TITLE_DEFAULT = 'table_map'

      attr_accessor :index_ws_title, :logger

      class Client
        def initialize(issuer, pem_path='client.pem')
          @issuer         = issuer
          @signing_key    = Google::APIClient::KeyUtils.load_from_pem(pem_path, 'notasecret')
          @index_ws_title = INDEX_WS_TITLE_DEFAULT
          @logger         = Logger.new(STDOUT)
        end

        def client
          client = Google::APIClient.new(:application_name => APPLICATION_NAME)
          client.authorization = Signet::OAuth2::Client.new(
            :token_credential_uri => TOKEN_CREDENTIAL_URI,
            :audience             => AUDIENCE,
            :scope                => SCOPE,
            :issuer               => @issuer,
            :signing_key          => @signing_key,
          )

          client.authorization.fetch_access_token!

          return client
        end

        def access_token
          return self.client.authorization.access_token
        end

        def session
          unless self.instance_variable_defined?(:@session) then
            @session = GoogleDrive.login_with_oauth(self.access_token)
          end

          return @session
        end

        def merge(base_ss_key, diff_ss_key, ws_title)
          session = self.session

          base_ss = session.spreadsheet_by_key(base_ss_key)
          diff_ss = session.spreadsheet_by_key(diff_ss_key)

          base_ss.merge(diff_ss, ws_title)
        end

        def merge_by_index_ws(base_index_ws, diff_index_ws)
          base_index_rows = base_index_ws.populated_rows

          diff_index_ws.populated_rows.each do |diff_index_row|
            base_index_row = base_index_rows.select { |row|
              row.sheetname == diff_index_row.sheetname
            }.first

            self.merge(base_index_row.key, diff_index_row.key, diff_index_row.sheetname)
          end
        end

        def merge_by_index_ss_key(base_index_ss_key, diff_index_ss_key)
          session = self.session

          base_index_ss = session.spreadsheet_by_key(base_index_ss_key)
          base_index_ws = base_index_ss.worksheet_by_title(@index_ws_title)

          diff_index_ss = session.spreadsheet_by_key(diff_index_ss_key)
          diff_index_ws = diff_index_ss.worksheet_by_title(@index_ws_title)

          self.merge_by_index_ws(base_index_ws, diff_index_ws)
        end

        def dry_merge_by_index_ss_key(base_index_ss_key, diff_index_ss_key, base_collection_url)
          session = self.session

          backup_index_ss_key = self.backup(base_index_ss_key, base_collection_url)

          backup_index_ss = session.spreadsheet_by_key(backup_index_ss_key)
          backup_index_ws = backup_index_ss.worksheet_by_title(@index_ws_title)

          diff_index_ss = session.spreadsheet_by_key(diff_index_ss_key)
          diff_index_ws = diff_index_ss.worksheet_by_title(@index_ws_title)

          self.merge_by_index_ws(backup_index_ws, diff_index_ws)
        end

        def backup(index_ss_key, base_collection_url, backup_collection_name="backup")
          session = self.session

          base_collection   = session.collection_by_url(base_collection_url)
          backup_collection = base_collection.create_subcollection(backup_collection_name)

          index_ss = session.spreadsheet_by_key(index_ss_key)
          index_ws = index_ss.worksheet_by_title(@index_ws_title)

          backup_index_ss = index_ss.duplicate(index_ss.title)
          backup_index_ws = backup_index_ss.worksheet_by_title(@index_ws_title)

          backup_collection.add(backup_index_ss)

          ss_keys = index_ws.populated_rows.map { |row| row.key }.uniq
          ss_keys.each do |ss_key|
            ss        = session.spreadsheet_by_key(ss_key)
            backup_ss = ss.duplicate(ss.title)

            backup_index_ws.populated_rows.each do |row|
              if row.key == ss_key then
                row.key = backup_ss.key
              end
            end

            backup_collection.add(backup_ss)
          end

          backup_ss_keys = backup_index_ws.populated_rows.map { |row| row.key }.uniq
          ss_keys.each do |ss_key|
            if backup_ss_keys.include?(ss_key) then
              backup_collection.delete
              @logger.warn 'fail in duplication'
              raise
            end
          end

          backup_index_ws.save

          return backup_index_ss.key
        end
      end
    end
  end
end

module GoogleDrive
  class Spreadsheet
    define_method 'can_merge?' do |target_ss, ws_title|
      base_ws   = self.worksheet_by_title(ws_title)
      target_ws = target_ss.worksheet_by_title(ws_title)
      unless base_ws.same_header?(target_ws) then
        @logger.warn "can not merge worksheet: #{target_ws.title}"
        return false
      end
      return true
    end

    define_method 'merge' do |diff_ss, ws_title|
      unless self.can_merge?(diff_ss, ws_title) then
        @logger.warn "can not merge spreadsheet: #{diff_ss.title}"
        raise
      end

      base_ws = self.worksheet_by_title(ws_title)
      diff_ws = diff_ss.worksheet_by_title(ws_title)

      diff_rows = diff_ws.populated_rows
      diff_rows.each do |diff_row|
        row = base_ws.append_row
        diff_ws.header.each do |column|
          row.send("#{column}=", diff_row.send("#{column}"))
        end
      end

      base_ws.save
    end
  end

  class Worksheet
    define_method 'same_header?' do |target_ws|
      return self.header == target_ws.header
    end
  end
end
