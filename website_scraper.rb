require "httparty"
require "nokogiri"
require "parallel"
require 'sanitize'
require 'csv'
require 'uri'
require 'valid_email2'

# debug
require "byebug"

class WebsiteScraper
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"  
  BLACKLIST_DOMAINS = %w[
    example.com
    example.org
    example.net
    test.com
    test.org
    test.net
    domain.com
    localhost
    localdomain
    sentry.io
    wixpress.com
    wix.com
    no-reply.com
    noreply.com
    invalid.com
  ]

  def initialize(csv_file, options = {})
    @csv_file = csv_file
    @threads = options[:threads] || 4
    @timeout = options[:timeout] || 10
    @semaphore = Mutex.new
    @updated_rows = []
  end

  def run
    starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    
    csv_table = CSV.table(@csv_file)
    headers = csv_table.headers
    
    unless headers.include?(:site)
      puts "Error: CSV must have a 'site' column"
      return
    end
    
    puts "Processing #{csv_table.length} rows..."
    puts "Headers found: #{headers.join(', ')}"
    
    rows_to_process = []
    csv_table.each_with_index do |row, index|
      rows_to_process << [row, index]
    end
    
    Parallel.each(rows_to_process, in_threads: @threads) do |row_data|
      row, index = row_data
      puts "Processing row #{index + 1}/#{csv_table.length}"
      
      site = row[:site] || row[:website] || row[:url]
      next if site.nil? || site.to_s.strip.empty?
      
      needs_email = (row[:email].nil? || row[:email].to_s.strip.empty?)
      needs_socials = (row[:socials].nil? || row[:socials].to_s.strip.empty?)
      
      next unless needs_email || needs_socials
      
      site_url = prepare_url(site.to_s)
      
      if site_url.include?("intuit.com")
        puts "  Skipping #{site_url} (blocked domain)"
        next
      end

      puts "  Scraping #{site_url} for: #{[needs_email ? 'email' : nil, needs_socials ? 'socials' : nil].compact.join(', ')}"
      
      scraped_data = scrape_site(site_url, {
        email: needs_email,
        socials: needs_socials
      })
      
      @semaphore.synchronize do
        if scraped_data[:email] && needs_email
          email = scraped_data[:email]
          if ValidEmail2::Address.new(email).valid? &&
             !ValidEmail2::Address.new(email).disposable? &&
             !BLACKLIST_DOMAINS.any? { |d| email.downcase.include?(d) }

            existing = (csv_table[index][:email] || "").split(";").map(&:strip)
            merged   = (existing + [email]).reject(&:empty?).uniq

            if merged.size <= 3
              csv_table[index][:email] = merged.join("; ")
              puts "  ✅ Added email: #{email}"
            else
              puts "  ⚠️ Too many emails (#{merged.size}), skipping further adds"
            end
          else
            puts "  ❌ Ignored email: #{email}"
          end
        end

        if scraped_data[:socials] && needs_socials
          existing = (csv_table[index][:socials] || "").split(";").map(&:strip)
          new_socials = scraped_data[:socials].split(";").map(&:strip)
          merged = (existing + new_socials).reject(&:empty?).uniq

          if merged.size <= 3
            csv_table[index][:socials] = merged.join("; ")
            puts "  ✅ Added socials: #{new_socials.join("; ")}"
          else
            puts "  ⚠️ Too many socials (#{merged.size}), skipping further adds"
          end
        end

        @updated_rows << index if scraped_data.values.any?
      end
    end
    
    puts "\n" + "="*50
    puts "Updateing CSV..."

    CSV.open(@csv_file, 'w', headers: headers, write_headers: true) do |csv|
      csv_table.each { |row| csv << row }
    end

    puts "CSV Updated!"
    
    ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = ending - starting
    puts "\n" + "="*50
    puts "Total time: #{elapsed.round(2)} seconds"
    puts "Updated #{@updated_rows.length} rows"
  end

  private

  def prepare_url(site)
    site = site.strip
    site = site.sub(%r{^https?:(//|\\\\)(www\.)?}i, '')
    site = site.split('/').first
    "https://#{site}"
  end

  def scrape_site(site, needs)
    result = {}
    
    pages_to_check = [
      '', '/about', '/contact', '/contact-us', '/about-us', '/contactus', '/aboutus', 'team', 'teams'
    ]
    
    pages_to_check.each do |page_path|
      break if has_all_needed?(result, needs)
      
      url = "#{site}#{page_path}"
      
      begin
        response = fetch_page(url)
        body = Nokogiri::HTML(response.body)

        next if response.body.nil? || response.code >= 400

        if needs[:email] && result[:email].nil?
          result[:email] = parse_email(body)
        end
        
        if needs[:socials] && result[:socials].nil?
          result[:socials] = parse_socials(body)
        end
        
      rescue StandardError
        next
      end
    end
    
    result
  end

  def fetch_page(url)
    HTTParty.get(url, {
      headers: { "User-Agent" => USER_AGENT },
      timeout: @timeout,
      follow_redirects: true,
      limit: 3
    })
  rescue Net::OpenTimeout, Net::ReadTimeout
    puts "  Timeout for #{url}"
    nil
  rescue StandardError
    nil
  end

  def has_all_needed?(result, needs)
    (!needs[:email] || result[:email]) &&
    (!needs[:socials] || result[:socials])
  end

  def parse_email(body)
    mailto_links = body.xpath("//a[starts-with(@href, 'mailto:')]/@href")
    if mailto_links.any?
      emails = mailto_links.map { |link| link.value.gsub('mailto:', '').split('?').first }.uniq
      valid_email = emails.find { |e| e =~ /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i }
      return valid_email if valid_email
    end
    
    email_pattern = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/
    
    priority_selectors = [
      "//div[contains(@class, 'contact')]",
      "//section[contains(@class, 'contact')]",
      "//div[contains(@class, 'email')]",
      "//span[contains(@class, 'email')]",
      "//p[contains(@class, 'email')]",
      "//div[@id='contact']",
      "//footer",
      "//div[contains(@class, 'footer')]"
    ]
    
    priority_selectors.each do |selector|
      elements = body.xpath(selector)
      elements.each do |element|
        emails = element.text.scan(email_pattern)
        emails = emails.reject { |e| e.include?('example.') || e.include?('@2x.') }
        return emails.first if emails.any?
      end
    end
    
    all_text = body.text
    all_emails = all_text.scan(email_pattern)
    all_emails = all_emails.reject { |e| e.include?('example.') || e.include?('@2x.') || e.include?('sentry.io') }
    all_emails.uniq.first
  end

  def parse_socials(body)
    socials_patterns = ["facebook.com", "linkedin.com", "fb.com", "fb.me", "lnkd.in"]
    socialss = []

    all_links = body.xpath("//a[@href]")
    all_links.each do |link|
      href = link['href'].to_s
      socials_patterns.each do |pattern|
        if href.include?(pattern)
          socials_url = href
          socials_url = "https:#{socials_url}" if socials_url.start_with?('//')
          socials_url = "https://#{socials_url}" unless socials_url.start_with?('http')

          next if socials_url.include?('sharer') || socials_url.include?('share.php')

          socialss << socials_url unless socialss.include?(socials_url)
        end
      end
    end

    socialss.empty? ? nil : socialss.uniq.join("; ")
  end
end

# CLI usage
if __FILE__ == $0
  require 'optparse'
  
  options = { threads: 4, timeout: 10 }
  
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby smart_scraper.rb CSV_FILE [options]"
    
    opts.on("-t", "--threads N", Integer, "Number of parallel threads (default: 4)") do |t|
      options[:threads] = t
    end
    
    opts.on("--timeout N", Integer, "HTTP timeout in seconds (default: 10)") do |t|
      options[:timeout] = t
    end
    
    opts.on("-h", "--help", "Show this help message") do
      puts opts
      exit
    end
  end.parse!
  
  if ARGV.empty?
    puts "Error: Please provide a CSV file"
    puts "Usage: ruby smart_scraper.rb your_file.csv"
    exit 1
  end
  
  csv_file = ARGV[0]
  
  unless File.exist?(csv_file)
    puts "Error: File '#{csv_file}' not found"
    exit 1
  end
  
  scraper = WebsiteScraper.new(csv_file, options)
  scraper.run
end