require "httparty"
require "nokogiri"
require "parallel"
require "selenium-webdriver"
require 'uri'

list_of_sites = ['https://www.blackhurstfamilydental.com/']

struct = Struct.new(:site, :email, :facebook, :phone)

list_of_info = []

semaphore = Mutex.new
csv_headers = ['site', 'email', 'facebook']

Parallel.map(list_of_sites, in_threads: 2) do |site|
  begin
    puts "Getting #{site}"

    response = HTTParty.get(site, {
      headers: {
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36"
      },
    })

    doc = Nokogiri::HTML(response.body)

    email_selector = "//a[starts-with(@href, \"mailto:\")]/@href"
    emails = doc.xpath(email_selector)
    email  = emails.collect {|n| n.value[7..-1]}.uniq.first if emails.any?



    facebook_selector = "//a[starts-with(@href, \"https://www.facebook.com\")]/@href"
    facebooks = doc.xpath(facebook_selector)
    facebook = facebooks.map(&:to_s).uniq.first if facebooks.any?

    phone_selector = "//a[starts-with(@href, \"tel:\")]/@href"
    phones = doc.xpath(phone_selector)
    phone = phones.collect {|n| n.value[4..-1]}.uniq.first

    puts "Got the email - #{email}"
    puts "Got the facebook - #{facebook}"
    puts "Got the phone - #{phone}"
  rescue
    puts "Warning #{site} is not available!"
  end

  info_struct = struct.new(site, email, facebook, phone)

  semaphore.synchronize {
    list_of_info.push(info_struct)
  }

  puts "info_struct - #{info_struct}"
end

puts "Total of #{list_of_info.count}"

puts "Starting CSV!"


CSV.open("output.csv", "wb", write_headers: true, headers: csv_headers) do |csv|
  list_of_info.each do |info|
    puts "Writing #{info.site} & #{info.email}"
    csv << info
  end
end

puts "Done!"



