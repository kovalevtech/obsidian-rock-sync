// The admin panel's few behaviours, wired by data attributes: no inline handlers, so its Content-Security-Policy
// (admin.rb) runs scripts from this file only

document.addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button) return;
  if (button.dataset.copy !== undefined) {
    // A Copy button: a check once copied (a value's), or its label says so (the token's)
    navigator.clipboard.writeText(button.dataset.copy).then(() => {
      button.classList.add('copied');
      button.title = 'Copied';
      const label = button.querySelector('span');
      if (label) label.textContent = 'Copied';
    });
  } else if (button.hasAttribute('data-add-grant')) {
    // A grant row from the template, its index unique (the form's names: grants[<i>][…])
    const row = document.getElementById('grant-row').innerHTML.replaceAll('__i__', Date.now());
    button.form.querySelector('table.grants').insertAdjacentHTML('beforeend', row);
  } else if (button.hasAttribute('data-remove-grant')) {
    button.closest('tbody').remove(); // its purpose and error rows along
  }
});

// "Show revoked": the list again at once
document.addEventListener('change', (event) => {
  if (event.target.matches('[data-submit-on-change]')) event.target.form.submit();
});

// Revoke: asks first
document.addEventListener('submit', (event) => {
  const question = event.target.dataset.confirm;
  if (question && !window.confirm(question)) event.preventDefault();
});
