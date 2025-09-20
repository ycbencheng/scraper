class EventLogger
  EVENT_ICONS = {
    incoming: "⇦ INCOMING from Intuit",
    outgoing: "⇨ OUTGOING request to Intuit",
    blocked:  "🚫 BLOCKED by Intuit",
    success:  "✅ SUCCESS",
    error:    "❌ ERROR"
  }.freeze

  def self.log(type, message)
    time = Time.now.strftime("%H:%M:%S")
    label = EVENT_ICONS[type] || ""
    puts "[#{time}] #{label}\n #{message}"
  end
end
