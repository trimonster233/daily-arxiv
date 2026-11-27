let currentPaperRequest;

function beginPaperRequest() {
  currentPaperRequest?.abort();
  currentPaperRequest = new AbortController();
  return currentPaperRequest.signal;
}

function closeDatePicker() {
  document.getElementById('datePickerModal').classList.remove('active');
  document.body.style.overflow = '';
}

function initDatePicker(dates, selectDay, selectRange, allowEmptyDay = false) {
  if (!dates.length) return;
  const modal = document.getElementById('datePickerModal');
  const input = document.getElementById('datepicker');
  const title = modal.querySelector('.date-picker-title');
  const rangeSwitch = document.getElementById('dateRangeMode');
  let appliedDates = [dates[0]];
  let picker;

  function showCalendar() {
    if (picker) picker.destroy();
    const range = rangeSwitch.checked;
    const selection = range
      ? (appliedDates.length === 2 ? appliedDates : [])
      : appliedDates.slice(-1);
    title.textContent = range ? 'Select start and end dates' : 'Select Date';
    picker = flatpickr(input, {
      inline: true,
      disableMobile: true,
      mode: range ? 'range' : 'single',
      dateFormat: 'Y-m-d',
      defaultDate: selection,
      maxDate: dates[0],
      // A range may cross days with no publication, including weekends.
      ...(range || allowEmptyDay ? {} : { enable: dates }),
      onChange(selected, value, calendar) {
        if (range && selected.length === 1) {
          title.textContent = 'Select the end date';
          return;
        }
        if (selected.length !== (range ? 2 : 1)) return;
        const nextDates = selected.map(day => calendar.formatDate(day, 'Y-m-d'));
        if (range && !dates.some(day => day >= nextDates[0] && day <= nextDates[1])) {
          alert('No available papers in the selected date range.');
          calendar.clear(false);
          title.textContent = 'Select start and end dates';
          return;
        }
        appliedDates = nextDates;
        if (range) selectRange(...nextDates);
        else selectDay(nextDates[0]);
        closeDatePicker();
      }
    });
    if (!selection.length) picker.jumpToDate(appliedDates[0]);
    input.style.display = 'none';
  }

  document.getElementById('calendarButton').addEventListener('click', () => {
    showCalendar();
    modal.classList.add('active');
    document.body.style.overflow = 'hidden';
  });
  modal.addEventListener('click', event => {
    if (event.target === modal) closeDatePicker();
  });
  rangeSwitch.addEventListener('change', showCalendar);
}
