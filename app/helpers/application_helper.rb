module ApplicationHelper
  def page_title_tag
    tag.title [ @page_title, Current.account&.name, "PaidJar" ].compact.uniq.join(" | ")
  end
end
