require "httparty"
require "nokogiri"
require "parallel"
require "byebug"

class Scraper
  def initialize(csv)
    @csv = csv
    @company = Struct.new(:name, :email, :site, :facebook, :phone)
    @companies = []
    @semaphore = Mutex.new
    @csv_headers = %w(name, email, site, facebook, phone)
    @body = nil
  end

  def run
    csv = CSV.table(@csv)
    scrape(csv[:site])
  end

  def scrape(sites)
    puts "Start scraping"

    Parallel.map(sites, in_threads: 4) do |site|
      puts "Getting info on - #{site}"

      html = html_response(site)

      if html.code < 400
        @body = Nokogiri::HTML(html.body)

        email = parse_email
        facebook = parse_fb
        phone = parse_phone
        # n = parse_name
      else
        puts "Warning #{site} is not available!"
      end

      company_struct = @company.new(n, email, site, facebook, phone)

      @semaphore.synchronize {
        @companies.push(company_struct)
      }
    end

    puts "Total of #{@companies.count}"

    create_csv
  end

  private

  def create_csv
    puts "Creating a new CSV!"

    CSV.open("#{@csv}_info.csv", "wb", write_headers: true, headers: @csv_headers) do |csv|
      @companies.each do |company|
        puts "Writing #{company.site} & #{company.email}"
        csv << company
      end
    end

    puts "Done!"
  end

  def html_response(site)
    HTTParty.get(site, {
      headers: {
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36"
      },
    })
  end

  def parse_name
    # parse for dr name or manager, or front desk
    data = extractor(selector("//a[starts-with(@href, \"#{label}\")]/@href"))
    cleaned_data = names
    logging(__method__, cleaned_data)
  end

  def parse_email
    # parse better email
    data = extractor(href_selector("mailto:"))
    cleaned_data = data.collect {|n| n.value[7..-1]}.uniq.first if data.any?
    logging(__method__, cleaned_data)
    data
  end

  def parse_fb
    data = extractor(href_selector("https://www.facebook.com"))
    cleaned_data = data.map(&:to_s).uniq.first if data.any?
    logging(__method__, cleaned_data)
    data
  end

  def parse_phone
    data = extractor(href_selector("tel:"))
    cleaned_data = data.collect {|n| n.value[4..-1]}.uniq.first if data.any?
    logging(__method__, cleaned_data)
    data
  end

  def href_selector(label)
    "//a[starts-with(@href, \"#{label}\")]/@href"
  end

  def extractor(selector)
    @body.xpath(selector)
  end

  def logging(method, data)
    puts "#{method} - #{data}"
  end
end
