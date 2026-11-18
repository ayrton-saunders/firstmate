require 'yaml'
require 'date'
require 'json'
require 'open3'
old_text, status = Open3.capture2('git','show','ebd520e74e04ab61fda68d20be71e9b9fa573105:.github/workflows/ci.yml')
raise 'cannot read baseline' unless status.success?
old = YAML.safe_load(old_text, permitted_classes: [Date, Time], aliases: true)
now = YAML.load_file('.github/workflows/ci.yml')
raise 'job identities changed' unless old['jobs'].keys == now['jobs'].keys
changed = old['jobs'].keys.select { |job| old['jobs'][job] != now['jobs'][job] }
raise "unexpected job changes: #{changed}" unless changed == ['tests-portable-parallel-1','tests-portable-parallel-2']
p1 = old['jobs']['tests-portable-parallel-1']
removed = p1['steps'].select { |s| s['name'] == 'Install the Pi package for the Pi extension tests' }
raise 'ambiguous Pi prerequisite' unless removed.length == 1
p1['steps'] -= removed
raise 'other lane 1 semantics changed' unless p1 == now['jobs']['tests-portable-parallel-1']
p2 = old['jobs']['tests-portable-parallel-2']
raise 'baseline checkout not full history' unless p2['steps'][0]['with'] == {'fetch-depth'=>0}
p2['steps'][0].delete('with')
raise 'other lane 2 semantics changed' unless p2 == now['jobs']['tests-portable-parallel-2']
puts JSON.pretty_generate({surface: 'Normalized GitHub Actions YAML contract, not a hosted workflow execution', changed_jobs: changed, unchanged_jobs: now['jobs'].keys - changed, lane_1_change: 'Only redundant global Pi installation removed; strict SDK prerequisite gate-skip check retained', lane_2_change: 'Only checkout depth changes from full history to action default', required_check_names_and_conditions: 'unchanged', stock_macos_job: 'semantically identical', hosted_execution: 'Not performed: CI execution belongs to the outer executor, not this local test phase'})
