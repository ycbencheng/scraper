require "nokogiri"
require "uri"

require_relative "qb_scraper_config"

class ProadvisorParser
  ACCOUNTANT_SELECTORS = [
    "h1.accountant-name", "h1[class*='name']", "div.profile-name h1", "div[class*='accountant'] h1",
    "h2.accountant-name", "span.accountant-name", "div.name-container", "h1", ".profile-header h1"
  ].freeze

  TITLE_SELECTORS = [
    "div.title", "span.title", "p.designation", "div.professional-title", "span.job-title",
    "div[class*='title']", "span[class*='designation']", "//*[@data-testid='professional-title']"
  ].freeze

  def initialize(proadvisor_struct)
    @proadvisor_struct = proadvisor_struct
  end

  def parse(html, url)
    body = Nokogiri::HTML(html)

    accountant_name = extract_text_by_selectors(body, ACCOUNTANT_SELECTORS)
    title_text = extract_text_by_selectors(body, TITLE_SELECTORS)
    emails = parse_emails_from_body(body)
    social_sites = parse_social_sites_from_body(body)
    site = parse_site_from_body(body)

    @proadvisor_struct.new(accountant_name, title_text, emails, social_sites, url, site, nil)
  rescue StandardError => e
    @proadvisor_struct.new(nil, nil, nil, nil, url, nil, "Scraping Error - #{e.message}")
  end

  private

  def extract_text_by_selectors(body, selectors)
    selectors.each do |sel|
      begin
        element = sel.start_with?("//") ? body.xpath(sel).first : body.css(sel).first
        next unless element

        text = element.text.strip
        return text unless text.empty?
      rescue StandardError
        next
      end
    end
    nil
  end

  def parse_emails_from_body(body)
    emails = []
    mailto = body.xpath("//a[starts-with(@href, 'mailto:')]/@href")
    emails += mailto.map { |l| l.value.sub('mailto:', '') }
    email_pattern = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/
    emails += body.text.scan(email_pattern)
    contacts = body.xpath("//div[contains(@class, 'contact')]//text() | //section[contains(@class, 'contact')]//text()")
    contacts.each { |t| emails += t.to_s.scan(email_pattern) }
    emails.uniq.join("; ")
  end

  def parse_social_sites_from_body(body)
    all_links = body.xpath("//a[@href]").map { |l| l['href'].to_s.strip }.compact

    social = all_links.select do |link|
      begin
        host = URI.parse(link).host.to_s.downcase
        next false if host.empty?

        QbScraperConfig::SOCIAL_DOMAINS.any? do |domain|
          host == domain || host.end_with?(".#{domain}")
        end
      rescue URI::InvalidURIError
        false
      end
    end

    social.uniq.join("; ")
  end

  def parse_site_from_body(body)
    websites = []
    QbScraperConfig::WEBSITE_SELECTORS.each do |sel|
      links = body.xpath(sel)
      websites += links.map(&:value)
    end

    websites = websites.select do |u|
      u.start_with?('http') && QbScraperConfig::WEBSITE_EXCLUDED_DOMAINS.none? { |d| u.include?(d) }
    end

    websites.uniq.join("; ")
  end
end
