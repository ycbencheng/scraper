require "httparty"
require "nokogiri"
require "parallel"
require "phonelib"
require 'sanitize'

# debug
require "byebug"

class Scraper
  def initialize(csv)
    @csv = csv
    @company = Struct.new(:email, :site, :facebook, :phone, :html, :error)
    @companies = []
    @semaphore = Mutex.new
    @csv_headers = %w(email site facebook phone html error)
    @body = nil
  end

  def run
    starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    csv = CSV.table(@csv)
    clean_sites = dedup(csv[:site])
    scrape(clean_sites)
    create_csv

    ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = ending - starting
    puts "Total time - #{elapsed.round(2)} second"
  end

  def dedup(sites)
    clean_sites = sites.map do |site|
      site.sub(%r{^https?:(//|\\\\)(www\.)?}i, '').split('/').first
    end.uniq

    puts "--- Total of #{clean_sites.count} sites!!! ---"

    clean_sites.map do |site|
      "https://#{site}"
    end
  end

  def scrape(sites)
    Parallel.map_with_index(sites, in_threads: 4) do |site, index|
      puts "#{index + 1}"

      begin
        raw_html = html_response(site)

        if raw_html.code < 400
          @body = Nokogiri::HTML(raw_html.body)

          email = parse_email
          facebook = parse_fb
          phone = parse_phone
        else
          error = "Error Code - #{html.code}"
        end
      rescue StandardError => e
        error = "Connection Error - #{e.message}"
      end

      html = Sanitize.fragment(raw_html)
      error = error ? "404" : ""

      company_struct = @company.new(email, site, facebook, phone, html, error)

      @semaphore.synchronize {
        @companies.push(company_struct)
      }
    end
  end

  private

  def create_csv
    CSV.open("#{@csv}_info.csv", "wb", write_headers: true, headers: @csv_headers) do |csv|
      @companies.each do |company|
        csv << company
      end
    end
  end

  def html_response(site)
    HTTParty.get(site, {
      headers: {
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36"
      },
    })
  end

  def parse_email
    data = extractor(href_selector("mailto:"))

    if data.any?
       data.collect {|n| n.value[7..-1]}.uniq.first
     else
       data = extractor("//*[contains(*, '.com')]")
       emails = data.text.scan(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[com]{2,4}\b/i)
       emails.uniq.first
     end
  end

  def parse_fb
    data = extractor(href_selector("https://www.facebook.com"))
    data.map(&:to_s).uniq.first if data.any?
  end

  def parse_phone
    data = extractor(href_selector("tel:"))

    if data.any
      num = data.collect {|n| n.value[4..-1]}.uniq.first
      Phonelib.parse(num, 'US').local_number
    end
  end

  def href_selector(label)
    "//a[starts-with(@href, \"#{label}\")]/@href"
  end

  def extractor(selector)
    @body.xpath(selector)
  end
end
