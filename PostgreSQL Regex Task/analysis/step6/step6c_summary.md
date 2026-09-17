# Step 6C measurement summary (generated)

Executions parsed: 1900 (950 per batch expected). Settings reported by EXPLAIN: {"jit": "off", "max_parallel_workers_per_gather": "0"}.
Sessions: batch 1 [{"pid": 14612, "started": "2026-09-12T09:46:08.22053+00:00", "server_version": "17.9", "read_only": "on", "settings": {"TimeZone": "UTC", "default_toast_compression": "pglz", "effective_cache_size": "524288", "jit": "off", "max_parallel_workers_per_gather": "0", "random_page_cost": "4", "shared_buffers": "16384", "track_io_timing": "on", "work_mem": "4096"}, "other_active_sessions": 0}, {"pid": 14612, "finished": "2026-09-12T09:50:02.914918+00:00"}]; batch 2 [{"pid": 52540, "started": "2026-09-12T09:50:03.010988+00:00", "server_version": "17.9", "read_only": "on", "settings": {"TimeZone": "UTC", "default_toast_compression": "pglz", "effective_cache_size": "524288", "jit": "off", "max_parallel_workers_per_gather": "0", "random_page_cost": "4", "shared_buffers": "16384", "track_io_timing": "on", "work_mem": "4096"}, "other_active_sessions": 0}, {"pid": 52540, "finished": "2026-09-12T09:54:20.214118+00:00"}].

Execution time in ms (includes output serialisation, SERIALIZE TEXT); median [p25-p75] of 15 runs, batch 1; batch 2 median.

| Query | Pattern | json median [IQR] | jsonb median [IQR] | jsonb/json | Batch 2 json / jsonb | Result |
|---|---|---|---|---:|---|---|
| Q01 | point lookup, whole document | 0.012 [0.011-0.014] | 0.030 [0.028-0.032] | 2.50 | 0.011 / 0.028 | measurable: json faster |
| Q02 | all whole documents (output serialisation) | 2.956 [2.798-3.120] | 68.709 [66.592-70.051] | 23.24 | 3.180 / 71.790 | measurable: json faster |
| Q03 | point lookup, one nested value | 0.035 [0.033-0.037] | 0.017 [0.016-0.018] | 0.49 | 0.040 / 0.019 | measurable: jsonb faster |
| Q04 | one nested scalar, all rows | 57.813 [56.075-61.155] | 11.134 [10.974-11.593] | 0.19 | 63.515 / 12.072 | measurable: jsonb faster |
| Q05 | ten nested scalars per row | 1069.889 [1046.866-1077.830] | 81.888 [80.127-85.197] | 0.08 | 1107.349 / 94.473 | measurable: jsonb faster |
| Q06 | all 70 leaves per row, cast back to column types | 7413.235 [7280.983-7906.262] | 592.191 [578.843-623.463] | 0.08 | 7494.955 / 613.074 | measurable: jsonb faster |
| Q07 | equality, very selective | 56.655 [55.694-60.711] | 10.253 [10.167-10.489] | 0.18 | 85.785 / 17.583 | measurable: jsonb faster |
| Q08 | equality, medium | 104.752 [102.436-106.343] | 10.700 [10.568-11.320] | 0.10 | 144.373 / 16.226 | measurable: jsonb faster |
| Q09 | equality, broad | 57.653 [56.925-59.753] | 10.671 [10.434-10.878] | 0.18 | 75.506 / 13.917 | measurable: jsonb faster |
| Q10 | integer equality | 110.982 [105.504-122.113] | 11.341 [10.963-12.475] | 0.10 | 118.120 / 12.193 | measurable: jsonb faster |
| Q11a | numeric range, medium | 119.987 [117.569-132.124] | 13.669 [13.433-13.868] | 0.11 | 176.349 / 20.899 | measurable: jsonb faster |
| Q11b | numeric range, broad | 184.372 [174.735-187.566] | 20.101 [19.649-21.969] | 0.11 | 195.531 / 21.446 | measurable: jsonb faster |
| Q12a | time window, 1 day (string range) | 155.207 [150.885-159.728] | 15.660 [14.982-16.372] | 0.10 | 161.201 / 16.592 | measurable: jsonb faster |
| Q12b | time window, 1 week (string range) | 154.690 [149.117-157.772] | 15.280 [14.984-16.731] | 0.10 | 163.746 / 16.371 | measurable: jsonb faster |
| Q12c | time window, 1 month (string range) | 156.042 [148.874-166.100] | 14.975 [14.730-15.340] | 0.10 | 161.267 / 16.544 | measurable: jsonb faster |
| Q13a | pattern, suffix | 106.807 [101.007-109.243] | 11.548 [11.305-12.336] | 0.11 | 127.487 / 12.879 | measurable: jsonb faster |
| Q13b | pattern, prefix | 104.854 [103.949-107.177] | 11.415 [10.914-13.261] | 0.11 | 113.373 / 12.395 | measurable: jsonb faster |
| Q14 | array membership (equivalent array function per type) | 64.069 [63.260-66.275] | 13.242 [12.962-13.519] | 0.21 | 67.298 / 14.120 | measurable: jsonb faster |
| Q15 | JSON null test | 106.269 [105.584-112.348] | 11.869 [11.388-13.291] | 0.11 | 121.574 / 12.618 | measurable: jsonb faster |
| Q16 | conjunction | 76.968 [75.502-82.114] | 12.145 [11.845-12.551] | 0.16 | 83.156 / 13.053 | measurable: jsonb faster |
| Q17 | group by nested text | 105.029 [102.136-117.410] | 11.596 [11.385-12.499] | 0.11 | 112.962 / 13.422 | measurable: jsonb faster |
| Q18 | group by two nested values | 220.851 [213.230-226.248] | 20.256 [19.882-21.548] | 0.09 | 225.855 / 21.206 | measurable: jsonb faster |
| Q19 | numeric aggregates | 393.824 [381.609-400.682] | 39.501 [37.487-42.049] | 0.10 | 398.281 / 41.471 | measurable: jsonb faster |
| Q20 | SQL/JSON JSON_VALUE | 126.457 [123.956-137.051] | 12.837 [11.949-13.481] | 0.10 | 131.761 / 12.816 | measurable: jsonb faster |
| Q21 | SQL/JSON JSON_EXISTS | 160.325 [141.116-175.472] | 14.897 [12.512-17.856] | 0.09 | 132.799 / 13.425 | measurable: jsonb faster |

| Query | Planning ms json / jsonb (median) | Planning result | Same plan shape | Plan shape (json) | Scan est. rows json / jsonb | Actual rows | Shared hit json / jsonb | Output kB json / jsonb | Serialisation ms json / jsonb (detail run) |
|---|---|---|---|---|---|---|---|---|---|
| Q01 | 0.024 / 0.025 | no measurable difference | True | Index Scan using T_pkey | 1 / 1 | 1 | 3 / 3 | 2 / 2 | 0.001 / 0.017 |
| Q02 | 0.029 / 0.032 | no measurable difference | True | Seq Scan on T | 5000 / 5000 | 5000 | 1250 / 981 | 8249 / 8986 | 1.870 / 67.379 |
| Q03 | 0.026 / 0.025 | no measurable difference | True | Index Scan using T_pkey | 1 / 1 | 1 | 3 / 3 | 1 / 1 | 0.001 / 0.001 |
| Q04 | 0.029 / 0.031 | no measurable difference | True | Seq Scan on T | 5000 / 5000 | 5000 | 1250 / 981 | 93 / 93 | 0.550 / 0.474 |
| Q05 | 0.050 / 0.048 | no measurable difference | True | Seq Scan on T | 5000 / 5000 | 5000 | 1250 / 981 | 1047 / 1047 | 3.720 / 2.987 |
| Q06 | 0.152 / 0.151 | no measurable difference | True | Seq Scan on T | 5000 / 5000 | 5000 | 1250 / 981 | 3796 / 3796 | 27.340 / 21.295 |
| Q07 | 0.028 / 0.030 | no measurable difference | True | Seq Scan on T | 25 / 25 | 12 | 1250 / 981 | 1 / 1 | 0.004 / 0.002 |
| Q08 | 0.031 / 0.043 | no measurable difference | True | Seq Scan on T | 25 / 25 | 225 | 1250 / 981 | 3 / 3 | 0.030 / 0.017 |
| Q09 | 0.030 / 0.031 | no measurable difference | True | Seq Scan on T | 25 / 25 | 1528 | 1250 / 981 | 15 / 15 | 0.118 / 0.115 |
| Q10 | 0.042 / 0.044 | no measurable difference | True | Seq Scan on T | 25 / 25 | 30 | 1250 / 981 | 1 / 1 | 0.008 / 0.003 |
| Q11a | 0.046 / 0.045 | no measurable difference | True | Seq Scan on T | 25 / 25 | 422 | 1250 / 981 | 5 / 5 | 0.068 / 0.028 |
| Q11b | 0.049 / 0.052 | no measurable difference | True | Seq Scan on T | 25 / 25 | 3064 | 1250 / 981 | 30 / 30 | 0.531 / 0.271 |
| Q12a | 0.046 / 0.047 | no measurable difference | True | Seq Scan on T | 25 / 25 | 13 | 1250 / 981 | 1 / 1 | 0.010 / 0.002 |
| Q12b | 0.037 / 0.045 | no measurable difference | True | Seq Scan on T | 25 / 25 | 108 | 1250 / 981 | 2 / 2 | 0.024 / 0.010 |
| Q12c | 0.043 / 0.040 | no measurable difference | True | Seq Scan on T | 25 / 25 | 498 | 1250 / 981 | 5 / 5 | 0.077 / 0.038 |
| Q13a | 0.039 / 0.039 | no measurable difference | True | Seq Scan on T | 8 / 8 | 545 | 1250 / 981 | 6 / 6 | 0.055 / 0.037 |
| Q13b | 0.042 / 0.037 | no measurable difference | True | Seq Scan on T | 25 / 25 | 173 | 1250 / 981 | 2 / 2 | 0.023 / 0.015 |
| Q14 | 0.044 / 0.046 | no measurable difference | True | Seq Scan on T [Function Scan <type>_array_elements_text] | 2500 / 2500 | 3 | 1250 / 981 | 1 / 1 | 0.002 / 0.001 |
| Q15 | 0.036 / 0.039 | no measurable difference | True | Seq Scan on T | 4975 / 4975 | 2941 | 1250 / 981 | 29 / 29 | 0.370 / 0.244 |
| Q16 | 0.037 / 0.043 | no measurable difference | True | Seq Scan on T | 1 / 1 | 78 | 1250 / 981 | 1 / 1 | 0.016 / 0.008 |
| Q17 | 0.038 / 0.051 | no measurable difference | True | Aggregate [Seq Scan on T] | 5000 / 5000 | 8 | 1250 / 981 | 1 / 1 | 0.004 / 0.004 |
| Q18 | 0.051 / 0.055 | no measurable difference | True | Aggregate [Seq Scan on T] | 5000 / 5000 | 32 | 1250 / 981 | 1 / 1 | 0.008 / 0.007 |
| Q19 | 0.057 / 0.064 | no measurable difference | True | Aggregate [Seq Scan on T] | 25 / 25 | 1 | 1250 / 981 | 1 / 1 | 0.005 / 0.004 |
| Q20 | 0.040 / 0.038 | no measurable difference | True | Seq Scan on T | 5000 / 5000 | 5000 | 1250 / 981 | 93 / 93 | 0.981 / 0.715 |
| Q21 | 0.047 / 0.051 | no measurable difference | True | Seq Scan on T | 2500 / 2500 | 30 | 1250 / 981 | 1 / 1 | 0.013 / 0.005 |

Problems: none
