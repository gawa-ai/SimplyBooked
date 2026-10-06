// Trades the map search understands. `niche` is sent as-is and stored on each lead it finds; the Lead Finder
// workflow (n8n/acq_phase2.py, TAGS) turns it into OpenStreetMap tags. n8n/acq_harness.js checks every entry maps.
export const TRADES = [
  { niche: 'Dentists', label: 'Dentists' },
  { niche: 'Doctors', label: 'Doctors and GP surgeries' },
  { niche: 'Clinics', label: 'Clinics' },
  { niche: 'Physiotherapists', label: 'Physiotherapists' },
  { niche: 'Podiatrists', label: 'Podiatrists' },
  { niche: 'Opticians', label: 'Opticians' },
  { niche: 'Hair salons', label: 'Hair salons' },
  { niche: 'Barbers', label: 'Barbers' },
  { niche: 'Beauty salons', label: 'Beauty salons' },
  { niche: 'Nail salons', label: 'Nail salons' },
  { niche: 'Spas', label: 'Spas' },
  { niche: 'Massage therapists', label: 'Massage therapists' },
  { niche: 'Gyms', label: 'Gyms' },
  { niche: 'Tattoo studios', label: 'Tattoo studios' },
  { niche: 'Garages', label: 'Garages and car repair' },
  { niche: 'Vets', label: 'Vets' },
  { niche: 'Pet groomers', label: 'Pet groomers' },
  { niche: 'Driving schools', label: 'Driving schools' },
];

export const COUNTRIES = [
  ['GB', 'United Kingdom'], ['IE', 'Ireland'], ['US', 'United States'], ['CA', 'Canada'], ['AU', 'Australia'],
  ['NZ', 'New Zealand'], ['ZA', 'South Africa'], ['AE', 'United Arab Emirates'], ['SG', 'Singapore'], ['PH', 'Philippines'],
];
