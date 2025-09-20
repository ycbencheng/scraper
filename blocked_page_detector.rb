require "nokogiri"

class BlockedPageDetector
  DEFAULT_BLOCKED_SELECTORS = [
    "#qba-matchmaking-ui-search-captcha",
    "h2.captcha-title",
    ".g-recaptcha",
    "form[action*='captcha']"
  ].freeze

  DEFAULT_BLOCKED_REGEX = /captcha|verify you are human|unusual traffic|security verification/i

  def initialize(selectors: DEFAULT_BLOCKED_SELECTORS, blocked_regex: DEFAULT_BLOCKED_REGEX, event_logger: nil, csv_logger: nil)
    @selectors = selectors.dup.freeze
    @blocked_regex = blocked_regex
    @event_logger = event_logger
    @csv_logger = csv_logger
  end

  def blocked?(html, url: nil)
    return false if html.to_s.strip.empty?

    body = Nokogiri::HTML(html)

    blocked = @blocked_regex.match?(body.text) ||
              @selectors.any? { |selector| !body.css(selector).empty? }

    if blocked
      @event_logger&.call(url: url, html: html)
      @csv_logger&.call(url: url, html: html)
    end

    blocked
  end
end