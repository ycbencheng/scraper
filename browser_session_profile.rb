require_relative "browser_session"

class BrowserSessionProfile
  def initialize(headless:, timeout:, accept_language:, retries:, proxy_list:, user_agents:)
    @headless = headless
    @timeout = timeout
    @accept_language = accept_language
    @retries = retries
    @proxy_list = proxy_list
    @user_agents = user_agents
    @proxy_assignments = {}
  end

  def build_session(session_id: Thread.current.object_id)
    BrowserSession.new(
      headless: @headless,
      timeout: @timeout,
      accept_language: @accept_language,
      retries: @retries,
      proxy: select_proxy(session_id),
      user_agent: select_user_agent
    )
  end

  private

  def select_user_agent
    return nil if @user_agents.nil? || @user_agents.empty?

    @user_agents.sample
  end

  def select_proxy(session_id)
    return nil if @proxy_list.nil? || @proxy_list.empty?

    return @proxy_list.sample unless session_id

    @proxy_assignments[session_id] ||= @proxy_list.sample
  end
end