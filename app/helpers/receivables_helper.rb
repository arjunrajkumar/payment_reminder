module ReceivablesHelper
  def receivable_amount(amount, currency)
    number_to_currency(
      amount || 0,
      unit: currency.present? ? "#{currency} " : "",
      precision: 2,
      strip_insignificant_zeros: true
    )
  end

  def receivable_totals(totals, qualifier: nil)
    return "0" if totals.empty?

    safe_join(
      totals.sort.map do |currency, amount|
        total = [ receivable_amount(amount, currency), qualifier.presence ].compact.join(" ")
        tag.span(total, class: "app-currency-total")
      end,
      tag.br
    )
  end
end
