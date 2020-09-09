# coding: utf-8
require 'rss'
require 'net/http'
require 'cgi'
require 'uri'
require 'yaml'
require 'nkf'

require 'rubygems'
require 'bundler/setup'
require 'grackle'
require 'nokogiri'

URL = 'https://www.2nn.jp/rss/news4plus.rdf'
REGEXP_HANIHANI = /(ちょーはにはにちゃんｗ|HONEY MILK(　)?|ハニィみるく（17歳）)φ? ★/

require 'aws-sdk-secretsmanager'
require 'aws-sdk-dynamodb'
require 'base64'
require 'logger'
require 'json'

logger = Logger.new($stdout)

def get_secret()
  secret_name = ENV['AWS_SECRET_NAME']
  region_name = "ap-northeast-1"

  client = Aws::SecretsManager::Client.new(region: region_name)

  # In this sample we only handle the specific exceptions for the 'GetSecretValue' API.
  # See https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html
  # We rethrow the exception by default.
  begin
    get_secret_value_response = client.get_secret_value(secret_id: secret_name)
  rescue Aws::SecretsManager::Errors::DecryptionFailure => e
    # Secrets Manager can't decrypt the protected secret text using the provided KMS key.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise
  rescue Aws::SecretsManager::Errors::InternalServiceError => e
    # An error occurred on the server side.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise
  rescue Aws::SecretsManager::Errors::InvalidParameterException => e
    # You provided an invalid value for a parameter.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise
  rescue Aws::SecretsManager::Errors::InvalidRequestException => e
    # You provided a parameter value that is not valid for the current state of the resource.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise
  rescue Aws::SecretsManager::Errors::ResourceNotFoundException => e
    # We can't find the resource that you asked for.
    # Deal with the exception here, and/or rethrow at your discretion.
    raise
  else
    # This block is ran if there were no exceptions.

    # Decrypts secret using the associated KMS CMK.
    # Depending on whether the secret is a string or binary, one of these fields will be populated.
    if get_secret_value_response.secret_string
      secret = get_secret_value_response.secret_string
      yield secret
    else
      decoded_binary_secret = Base64.decode64(get_secret_value_response.secret_binary)
      yield decoded_binary_secret
    end
  end
end


def post_to_twitter(grackle, title, url)
  status = sprintf('%s %s', title, url)
  if ENV['NO_TWEET']
    logger = Logger.new($stdout)
    logger.info("TWEET: #{status}")
  else
    grackle.statuses.update! :status => status
  end
end

def get_grackle_secret(secret)
  {
    :type => :oauth,
    :consumer_key => secret['OAUTH_CONSUMER_KEY'],
    :consumer_secret => secret['OAUTH_CONSUMER_SECRET'],
    :token => secret['OAUTH_ACCESS_TOKEN'],
    :token_secret => secret['OAUTH_ACCESS_SECRET']
  }
end


def http_get(url)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true if uri.scheme == 'https'
  http.start do |http|
    response = http.get(uri.path)
    case response
    when Net::HTTPResponse
      NKF.nkf('--utf8', response.body)
    else
      raise "Unable to retrieve file: #{response.to_s}"
    end
  end
end


def lambda_handler(event:, context:)  
  logger = Logger.new($stderr)

  get_secret() do |secret|
    secret_data = JSON.parse(secret)

    Grackle::Transport.ca_cert_file = "/etc/ssl/certs/ca-bundle.crt"
    grackle = Grackle::Client.new(:ssl => true, :auth => get_grackle_secret(secret_data))

    client = Aws::DynamoDB::Client.new(region: 'ap-northeast-1')
    now = Time.now.strftime("%Y-%m-%d %H:%M:%S")
    
    body = http_get(URL)
    if body then
      rss = RSS::Parser.parse(body, false)
      rss.items.each do |item|
        if REGEXP_HANIHANI =~ item.dc_creator then
          # eg: http://yutori7.2ch.net/test/read.cgi/news4plus/1259175497/

          doc = Nokogiri::HTML(item.description)
          url = doc.xpath("//a/@href").first.to_s
          uri = URI.parse(url)
          server = uri.host.split(/[.]/).first
          _, _, _, board, thread = *uri.path.split(/\//)
          next unless (board && thread)

          resp = client.get_item({
                                   table_name: 'daily_hanihani',
                                   key: {
                                     'url' => url
                                   }
                                 })
          if resp.item
            logger.debug(sprintf("UPDATE: [%s] %s", item.title.to_s, url))
            resp = client.update_item({
                                        table_name: 'daily_hanihani',
                                        key: {
                                          'url' => url
                                        },
                                        update_expression: 'SET #LC = :now',
                                        expression_attribute_names: {
                                          '#LC' => 'last_checked'
                                        },
                                        expression_attribute_values: {
                                          ':now' => now
                                        }              
                                      })
          else
            logger.debug(sprintf("INSERT: [%s] %s", item.title.to_s, url))
            resp = client.put_item({
                                     table_name: 'daily_hanihani',
                                     item: {
                                       'url' => url,
                                       'date' => item.dc_date.strftime("%Y-%m-%d %H:%M:%S"),
                                       'creator' => item.dc_creator.to_s,
                                       'title' => item.title.to_s,
                                       'last_checked' => now,
                                     }
                                   })
            
            post_to_twitter(grackle, item.title, item.link)
          end
        end
      end
    end

  end
  
  { statusCode: 200, body: JSON.generate('Hello from Lambda!') }
end

