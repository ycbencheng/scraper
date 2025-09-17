require "httparty"
require "nokogiri"
require "parallel"
require "phonelib"
require 'sanitize'
require 'csv'
require 'optparse'

class QbScraper
  def initialize(input_source = nil)
    @input_source = input_source
    @proadvisor = Struct.new(:accountant_name, :title_text, :emails, :social_sites, :proadvisor_link, :website_info, :error)
    @proadvisors = []
    @semaphore = Mutex.new
    @csv_headers = %w(accountant_name title_text emails social_sites proadvisor_link website_info error)
    @body = nil
  end

  def run(direct_urls = [])
    starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    urls = load_urls(direct_urls)
    
    if urls.empty?
      puts "No URLs provided. Please provide URLs via:"
      puts "  1. Command line arguments"
      puts "  2. A CSV file with -f option"
      puts "  3. A text file with -f option"
      puts "  4. Direct input with -u option"
      return
    end
    
    scrape_proadvisors(urls)
    create_csv

    ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = ending - starting
    puts "Total time - #{elapsed.round(2)} seconds"
  end

  private

  def load_urls(direct_urls)
    urls = []
    
    # If direct URLs are provided, use them
    if !direct_urls.empty?
      urls = direct_urls
    # If input source is provided (file)
    elsif @input_source
      if File.exist?(@input_source)
        if @input_source.end_with?('.csv')
          csv = CSV.table(@input_source)
          urls = csv[:url] || csv[:link] || csv[:site]
          urls = urls.compact.map(&:to_s)
        else
          urls = File.readlines(@input_source).map(&:strip).reject(&:empty?)
        end
      else
        puts "Error: File '#{@input_source}' not found!"
        return []
      end
    end
    
    # Clean and validate URLs
    urls = urls.map do |url|
      url = url.strip
      # Add https:// if no protocol is specified
      url = "https://#{url}" unless url.match?(/^https?:\/\//i)
      url
    end
    
    puts "--- Total of #{urls.count} ProAdvisor URLs to scrape ---"
    urls
  end

  def scrape_proadvisors(urls)
    Parallel.map_with_index(urls, in_threads: 4) do |url, index|
      puts "Processing #{index + 1} of #{urls.count}: #{url}"

      begin
        response = fetch_proadvisor_page(url)

        if response && response.code < 400
          @body = Nokogiri::HTML(response.body)
          
          accountant_name = parse_accountant_name
          title_text = parse_title_text
          emails = parse_emails
          social_sites = parse_social_sites
          website_info = parse_website_info
          error = nil
        else
          error = "HTTP Error - #{response&.code || 'Unknown'}"
        end
      rescue StandardError => e
        error = "Scraping Error - #{e.message}"
        puts "Error scraping #{url}: #{e.message}"
      end

      proadvisor_struct = @proadvisor.new(
        accountant_name,
        title_text,
        emails,
        social_sites,
        url,
        website_info,
        error
      )

      @semaphore.synchronize {
        @proadvisors.push(proadvisor_struct)
      }
    end
  end

  def fetch_proadvisor_page(url)
    HTTParty.get(url, {
      headers: {
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language" => "en-US,en;q=0.5",
        "Accept-Encoding" => "gzip, deflate, br",
        "DNT" => "1",
        "Connection" => "keep-alive",
        "Upgrade-Insecure-Requests" => "1",
        "Sec-Fetch-Dest" => "document",
        "Sec-Fetch-Mode" => "navigate",
        "Sec-Fetch-Site" => "none",
        "Cache-Control" => "max-age=0"
      },
      timeout: 30,
      follow_redirects: true
    })
  end

  def parse_accountant_name
    selectors = [
      "h1.accountant-name",
      "h1[class*='name']",
      "div.profile-name h1",
      "div[class*='accountant'] h1",
      "h2.accountant-name",
      "span.accountant-name",
      "div.name-container",
      "//h1[contains(@class, 'name')]",
      "//div[contains(@class, 'profile')]//h1",
      "//*[@data-testid='accountant-name']"
    ]
    
    extract_text_from_selectors(selectors)
  end

  def parse_title_text
    selectors = [
      "div.title",
      "span.title",
      "p.designation",
      "div.professional-title",
      "span.job-title",
      "div[class*='title']",
      "span[class*='designation']",
      "//div[contains(@class, 'title')]",
      "//span[contains(@class, 'designation')]",
      "//*[@data-testid='professional-title']"
    ]
    
    extract_text_from_selectors(selectors)
  end

  def parse_emails
    emails = []
    
    mailto_links = @body.xpath("//a[starts-with(@href, 'mailto:')]/@href")
    emails += mailto_links.map { |link| link.value.sub('mailto:', '') }
    
    email_pattern = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/
    text_emails = @body.text.scan(email_pattern)
    emails += text_emails
    
    contact_sections = @body.xpath("//div[contains(@class, 'contact')]//text() | //section[contains(@class, 'contact')]//text()")
    contact_sections.each do |text|
      emails += text.to_s.scan(email_pattern)
    end
    
    emails.uniq.join("; ")
  end

  def parse_social_sites
    social_links = []
    
    social_domains = [
      'facebook.com',
      'twitter.com',
      'x.com',
      'linkedin.com',
      'instagram.com',
      'youtube.com',
      'pinterest.com',
      'tiktok.com'
    ]
    
    social_domains.each do |domain|
      links = @body.xpath("//a[contains(@href, '#{domain}')]/@href")
      social_links += links.map(&:value)
    end
    
    social_icon_links = @body.xpath("//a[contains(@class, 'social') or contains(@class, 'icon')]/@href")
    social_icon_links.each do |link|
      url = link.value
      social_links << url if social_domains.any? { |domain| url.include?(domain) }
    end
    
    social_links.uniq.join("; ")
  end

  def parse_website_info
    websites = []
    
    website_selectors = [
      "//a[contains(@class, 'website')]/@href",
      "//a[contains(@class, 'url')]/@href",
      "//a[contains(text(), 'Website')]/@href",
      "//a[contains(text(), 'Visit')]/@href",
      "//div[contains(@class, 'website')]//a/@href"
    ]
    
    website_selectors.each do |selector|
      links = @body.xpath(selector)
      websites += links.map(&:value)
    end
    
    excluded_domains = ['facebook.com', 'twitter.com', 'linkedin.com', 'instagram.com', 'proadvisor.intuit.com', 'intuit.com']
    
    websites = websites.select do |url|
      !excluded_domains.any? { |domain| url.include?(domain) } && url.start_with?('http')
    end
    
    websites.uniq.join("; ")
  end

  def extract_text_from_selectors(selectors)
    selectors.each do |selector|
      begin
        if selector.start_with?('//')
          element = @body.xpath(selector).first