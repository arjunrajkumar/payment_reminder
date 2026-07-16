import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "goodDebtorRate",
    "badDebtorRate"
  ]

  connect() {
    this.updateOptionAvailability()
  }

  updateOptionAvailability() {
    this.disableOptionsAtOrBelow(this.goodDebtorRateTarget, this.badDebtorRate)
    this.disableOptionsAtOrAbove(this.badDebtorRateTarget, this.goodDebtorRate)
  }

  disableOptionsAtOrBelow(select, minimum) {
    this.updateOptions(select, value => value <= minimum)
  }

  disableOptionsAtOrAbove(select, maximum) {
    this.updateOptions(select, value => value >= maximum)
  }

  updateOptions(select, shouldDisable) {
    Array.from(select.options).forEach(option => {
      option.disabled = shouldDisable(Number(option.value))
    })
  }

  get goodDebtorRate() {
    return Number(this.goodDebtorRateTarget.value)
  }

  get badDebtorRate() {
    return Number(this.badDebtorRateTarget.value)
  }
}
