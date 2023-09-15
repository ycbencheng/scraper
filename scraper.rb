require "httparty"
require "nokogiri"
require "parallel"
require "byebug"

class Scraper
  def initialize(csv)
    @csv = csv
    @company = Struct.new(:name, :email, :site, :facebook, :phone, :error)
    @companies = []
    @semaphore = Mutex.new
    @csv_headers = %w(name, email, site, facebook, phone, error)
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

      begin
        html = html_response(site)
        if html.code < 400
          @body = Nokogiri::HTML(html.body)

          name = parse_name
          email = parse_email
          facebook = parse_fb
          phone = parse_phone
        else
          error = "Error Code - #{html.code}"
        end
      rescue StandardError => e
        error = "Connection Error - #{e.message}"
      end

      puts error ? error : "Got some info on the company"

      company_struct = @company.new(name, email, site, facebook, phone, error)

      @semaphore.synchronize {
        @companies.push(company_struct)
      }
    end

    puts "Total of #{@companies.count}"

    # dedup the site
    # skip if the site is mountainstar, ihc, stmarks, intermountainhealthcare, .gov, .edu, reverehealth, lenscrafter, target, walmart
    # check if the phone number, website is the same

    create_csv
  end

  private

  def create_csv
    puts "Creating a new CSV!"

    CSV.open("#{@csv}_info.csv", "wb", write_headers: true, headers: @csv_headers) do |csv|
      @companies.each do |company|
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
    data = extractor("//*[contains(*, \"dr\")]")

    _, raw_name = data.text.downcase.split('dr.')

    cleaned_data = if raw_name.nil?
                     nil
                   elsif raw_name.split().first == '.'
                     raw_name.split().first(2).unshift('Dr').insert(2, " ").map{|rn| rn.capitalize}.join()
                   else
                    raw_name.split().first(1).unshift('Dr').insert(1, " ").map{|rn| rn.capitalize}.join()
                   end

    logging(__method__, cleaned_data)

    cleaned_data
  end

  def parse_email
    data = extractor(href_selector("mailto:"))
    #look for span, div, p
    cleaned_data = if data.any?
                     data.collect {|n| n.value[7..-1]}.uniq.first
                   else
                     data = extractor("//*[contains(*, '.com')]")
                     emails = data.text.scan(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[com]{2,4}\b/i)
                     emails.uniq.first
                   end

    logging(__method__, cleaned_data)

    cleaned_data
  end

  def parse_fb
    data = extractor(href_selector("https://www.facebook.com"))
    cleaned_data = data.map(&:to_s).uniq.first if data.any?

    logging(__method__, cleaned_data)

    cleaned_data
  end

  def parse_phone
    data = extractor(href_selector("tel:"))
    # clean phone
    cleaned_data = data.collect {|n| n.value[4..-1]}.uniq.first if data.any?
    logging(__method__, cleaned_data)
    cleaned_data
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
