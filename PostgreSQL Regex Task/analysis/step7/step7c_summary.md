# Step 7C - generated measurement summary

session 1: @@ENV session=1 pid=48436 start=2026-09-12 21:14:29.292502+00 PostgreSQL 17.9 on x86_64-windows, compiled by msvc-19.44.35225, 64-bit
session 2: @@ENV session=2 pid=20940 start=2026-09-12 21:15:27.335919+00 PostgreSQL 17.9 on x86_64-windows, compiled by msvc-19.44.35225, 64-bit
executions parsed: 3840 + 3840; blocks with other active sessions: none; problems: none

## Index builds and sizes

| ID | index | method | build ms median [min-max] | WAL bytes median | size bytes | pages | table heap bytes / pages |
|---|---|---|---|---|---|---|---|
| N-1 | flat_numeric_btree_lat_lon_idx | btree | 3.793 [3.688-14.394] | 149928 | 180224 | 22 | 253952 / 31 |
| G-1 | flat_geom_gist_idx | gist | 9.073 [8.717-12.122] | 137576 | 212992 | 26 | 319488 / 39 |
| G-2 | flat_geom_spgist_idx | spgist | 10.607 [10.341-11.928] | 192840 | 278528 | 34 | 319488 / 39 |
| G-3 | flat_geom_brin_idx | brin | 3.322 [2.967-4.374] | 2024 | 24576 | 3 | 319488 / 39 |
| Y-1 | flat_geog_gist_idx | gist | 13.137 [13.026-14.219] | 206888 | 393216 | 48 | 319488 / 39 |
| Y-2 | flat_geog_spgist_idx | spgist | 13.387 [13.154-14.526] | 264896 | 376832 | 46 | 319488 / 39 |
| J-1 | jsonb_doc_expr_geom_gist_idx | gist | 38.385 [36.915-39.057] | 138824 | 212992 | 26 | 8036352 / 981 |
| J-2 | jsonb_doc_expr_geog_gist_idx | gist | 40.477 [39.831-40.830] | 208400 | 393216 | 48 | 8036352 / 981 |
| J-3 | jsonb_geom_gist_idx | gist | 9.669 [9.643-12.819] | 137600 | 212992 | 26 | 7200768 / 879 |
| J-4 | jsonb_geog_gist_idx | gist | 13.419 [13.411-17.756] | 207056 | 393216 | 48 | 7200768 / 879 |

## Class I - index vs control (session 1 medians ms [IQR]; verdict)

| block | indexed | control | indexed ms | control ms | ratio idx/ctrl | index used | verdict |
|---|---|---|---|---|---|---|---|
| B1 | B1@N-1 | B1@N-0 | 0.181 [0.179-0.198] | 0.569 [0.516-0.616] | 0.318 | 15/15 | measurable benefit |
| B1 | B1@G-1 | B1@G-0 | 0.245 [0.240-0.252] | 0.834 [0.796-0.883] | 0.294 | 15/15 | measurable benefit |
| B1 | B1@G-2 | B1@G-0 | 0.253 [0.234-0.275] | 0.834 [0.796-0.883] | 0.303 | 15/15 | measurable benefit |
| B1 | B1@G-3 | B1@G-0 | 0.884 [0.852-0.899] | 0.834 [0.796-0.883] | 1.060 | 0/15 | index not used by the planner |
| B1 | B1@J-1 | B1@J-0g | 2.500 [2.327-2.600] | 24.598 [22.922-25.277] | 0.102 | 15/15 | measurable benefit |
| B1 | B1@J-3 | B1@J-3c | 0.422 [0.391-0.442] | 1.501 [1.396-1.617] | 0.281 | 15/15 | measurable benefit |
| B2 | B2@N-1 | B2@N-0 | 0.268 [0.252-0.284] | 0.614 [0.549-0.642] | 0.436 | 15/15 | measurable benefit |
| B2 | B2@G-1 | B2@G-0 | 0.254 [0.238-0.267] | 0.851 [0.826-0.876] | 0.298 | 15/15 | measurable benefit |
| B2 | B2@G-2 | B2@G-0 | 0.279 [0.253-0.295] | 0.851 [0.826-0.876] | 0.328 | 15/15 | measurable benefit |
| B2 | B2@G-3 | B2@G-0 | 0.921 [0.893-0.938] | 0.851 [0.826-0.876] | 1.082 | 0/15 | index not used by the planner |
| B2 | B2@J-1 | B2@J-0g | 2.490 [2.448-2.570] | 25.293 [24.148-25.701] | 0.098 | 15/15 | measurable benefit |
| B2 | B2@J-3 | B2@J-3c | 0.419 [0.400-0.434] | 1.502 [1.468-1.529] | 0.279 | 15/15 | measurable benefit |
| B3 | B3@N-1 | B3@N-0 | 0.526 [0.494-0.553] | 0.869 [0.773-0.908] | 0.605 | 15/15 | measurable benefit |
| B3 | B3@G-1 | B3@G-0 | 1.056 [0.952-1.084] | 1.132 [1.023-1.176] | 0.933 | 15/15 | index used, no measurable benefit |
| B3 | B3@G-2 | B3@G-0 | 0.954 [0.893-1.024] | 1.132 [1.023-1.176] | 0.843 | 15/15 | index used, no measurable benefit |
| B3 | B3@G-3 | B3@G-0 | 1.150 [1.089-1.212] | 1.132 [1.023-1.176] | 1.016 | 0/15 | index not used by the planner |
| B3 | B3@J-1 | B3@J-0g | 8.877 [8.738-9.711] | 25.076 [23.906-26.511] | 0.354 | 15/15 | measurable benefit |
| B3 | B3@J-3 | B3@J-3c | 1.325 [1.242-1.400] | 1.799 [1.688-1.885] | 0.737 | 15/15 | measurable benefit |
| B4 | B4@N-1 | B4@N-0 | 1.275 [1.186-1.307] | 1.224 [1.107-1.307] | 1.042 | 0/15 | index not used by the planner |
| B4 | B4@G-1 | B4@G-0 | 2.528 [2.350-2.650] | 1.612 [1.488-1.706] | 1.568 | 15/15 | measurable regression |
| B4 | B4@G-2 | B4@G-0 | 2.354 [2.262-2.484] | 1.612 [1.488-1.706] | 1.460 | 15/15 | measurable regression |
| B4 | B4@G-3 | B4@G-0 | 1.740 [1.666-1.799] | 1.612 [1.488-1.706] | 1.079 | 0/15 | index not used by the planner |
| B4 | B4@J-1 | B4@J-0g | 23.150 [21.910-23.731] | 26.417 [24.339-27.429] | 0.876 | 15/15 | measurable benefit |
| B4 | B4@J-3 | B4@J-3c | 2.633 [2.462-2.730] | 2.374 [2.311-2.457] | 1.109 | 15/15 | index used, no measurable benefit |
| B5 | B5@N-1 | B5@N-0 | 0.912 [0.889-0.925] | 0.902 [0.850-0.935] | 1.011 | 0/15 | index not used by the planner |
| B5 | B5@G-1 | B5@G-0 | 0.038 [0.036-0.040] | 1.235 [1.195-1.271] | 0.031 | 15/15 | measurable benefit |
| B5 | B5@G-2 | B5@G-0 | 0.067 [0.057-0.069] | 1.235 [1.195-1.271] | 0.054 | 15/15 | measurable benefit |
| B5 | B5@G-3 | B5@G-0 | 1.504 [1.420-1.554] | 1.235 [1.195-1.271] | 1.218 | 15/15 | measurable regression |
| B5 | B5@J-1 | B5@J-0g | 0.050 [0.043-0.054] | 46.525 [45.320-46.925] | 0.001 | 15/15 | measurable benefit |
| B5 | B5@J-3 | B5@J-3c | 0.038 [0.037-0.041] | 2.041 [1.996-2.082] | 0.019 | 15/15 | measurable benefit |
| B6 | B6@N-1 | B6@N-0 | 0.018 [0.016-0.019] | 0.434 [0.404-0.496] | 0.041 | 15/15 | measurable benefit |
| B6 | B6@G-1 | B6@G-0 | 0.024 [0.021-0.025] | 0.754 [0.662-0.779] | 0.032 | 15/15 | measurable benefit |
| B6 | B6@G-2 | B6@G-0 | 0.042 [0.037-0.046] | 0.754 [0.662-0.779] | 0.056 | 15/15 | measurable benefit |
| B6 | B6@G-3 | B6@G-0 | 0.797 [0.734-0.839] | 0.754 [0.662-0.779] | 1.057 | 0/15 | index not used by the planner |
| B6 | B6@J-1 | B6@J-0g | 0.032 [0.029-0.035] | 24.026 [22.659-25.818] | 0.001 | 15/15 | measurable benefit |
| B6 | B6@J-3 | B6@J-3c | 0.024 [0.022-0.025] | 1.391 [1.226-1.472] | 0.017 | 15/15 | measurable benefit |
| D1 | D1@Y-1 | D1@Y-0 | 0.438 [0.412-0.452] | 7.745 [7.609-8.287] | 0.057 | 15/15 | measurable benefit |
| D1 | D1@Y-2 | D1@Y-0 | 0.789 [0.739-0.878] | 7.745 [7.609-8.287] | 0.102 | 15/15 | measurable benefit |
| D1 | D1@J-2 | D1@J-0y | 2.803 [2.657-2.897] | 33.305 [32.254-34.686] | 0.084 | 15/15 | measurable benefit |
| D1 | D1@J-4 | D1@J-4c | 0.560 [0.527-0.709] | 8.519 [8.267-9.069] | 0.066 | 15/15 | measurable benefit |
| D1 | MD1@G-1 | MD1@G-0 | 0.597 [0.540-0.634] | 1.147 [1.067-1.171] | 0.520 | 15/15 | measurable benefit |
| D2 | D2@Y-1 | D2@Y-0 | 1.146 [1.032-1.223] | 7.290 [6.996-7.802] | 0.157 | 15/15 | measurable benefit |
| D2 | D2@Y-2 | D2@Y-0 | 1.519 [1.424-1.543] | 7.290 [6.996-7.802] | 0.208 | 15/15 | measurable benefit |
| D2 | D2@J-2 | D2@J-0y | 6.950 [6.780-7.473] | 32.492 [31.217-35.066] | 0.214 | 15/15 | measurable benefit |
| D2 | D2@J-4 | D2@J-4c | 1.487 [1.440-1.783] | 7.867 [7.576-8.272] | 0.189 | 15/15 | measurable benefit |
| D2 | MD2@G-1 | MD2@G-0 | 1.798 [1.636-2.079] | 2.111 [1.906-2.329] | 0.852 | 15/15 | index used, no measurable benefit |
| D3 | D3@Y-1 | D3@Y-0 | 0.599 [0.557-0.641] | 7.437 [7.280-7.949] | 0.081 | 15/15 | measurable benefit |
| D3 | D3@Y-2 | D3@Y-0 | 0.930 [0.867-1.002] | 7.437 [7.280-7.949] | 0.125 | 15/15 | measurable benefit |
| D3 | D3@J-2 | D3@J-0y | 4.020 [3.859-4.282] | 31.665 [30.822-35.195] | 0.127 | 15/15 | measurable benefit |
| D3 | D3@J-4 | D3@J-4c | 0.911 [0.824-0.955] | 8.663 [8.135-8.886] | 0.105 | 15/15 | measurable benefit |
| D4 | D4@Y-1 | D4@Y-0 | 1.847 [1.807-2.023] | 5.657 [5.444-6.251] | 0.326 | 15/15 | measurable benefit |
| D4 | D4@Y-2 | D4@Y-0 | 2.259 [2.177-2.410] | 5.657 [5.444-6.251] | 0.399 | 15/15 | measurable benefit |
| D4 | D4@J-2 | D4@J-0y | 13.222 [12.322-14.085] | 30.961 [30.107-32.892] | 0.427 | 15/15 | measurable benefit |
| D4 | D4@J-4 | D4@J-4c | 2.556 [2.290-2.721] | 6.876 [6.314-7.311] | 0.372 | 15/15 | measurable benefit |
| D5 | D5@Y-1 | D5@Y-0 | 1.360 [1.220-1.483] | 8.189 [7.973-8.538] | 0.166 | 15/15 | measurable benefit |
| D5 | D5@Y-2 | D5@Y-0 | 1.632 [1.473-1.734] | 8.189 [7.973-8.538] | 0.199 | 15/15 | measurable benefit |
| D5 | D5@J-2 | D5@J-0y | 4.736 [4.449-5.353] | 33.550 [32.477-35.936] | 0.141 | 15/15 | measurable benefit |
| D5 | D5@J-4 | D5@J-4c | 1.625 [1.584-1.835] | 9.136 [8.662-9.598] | 0.178 | 15/15 | measurable benefit |
| D6 | D6@Y-1 | D6@Y-0 | 0.116 [0.105-0.149] | 8.168 [8.030-8.630] | 0.014 | 15/15 | measurable benefit |
| D6 | D6@Y-2 | D6@Y-0 | 0.448 [0.420-0.476] | 8.168 [8.030-8.630] | 0.055 | 15/15 | measurable benefit |
| D6 | D6@J-2 | D6@J-0y | 0.329 [0.282-0.357] | 33.963 [32.708-35.242] | 0.010 | 15/15 | measurable benefit |
| D6 | D6@J-4 | D6@J-4c | 0.098 [0.093-0.118] | 9.100 [8.895-9.512] | 0.011 | 15/15 | measurable benefit |
| D6 | MD6@G-1 | MD6@G-0 | 0.071 [0.063-0.072] | 0.648 [0.632-0.697] | 0.110 | 15/15 | measurable benefit |
| D7 | D7@Y-1 | D7@Y-0 | 0.042 [0.034-0.056] | 4.331 [4.162-4.565] | 0.010 | 15/15 | measurable benefit |
| D7 | D7@Y-2 | D7@Y-0 | 0.419 [0.354-0.483] | 4.331 [4.162-4.565] | 0.097 | 15/15 | measurable benefit |
| D7 | D7@J-2 | D7@J-0y | 0.057 [0.045-0.072] | 30.254 [29.318-30.602] | 0.002 | 15/15 | measurable benefit |
| D7 | D7@J-4 | D7@J-4c | 0.035 [0.029-0.041] | 5.157 [4.971-5.248] | 0.007 | 15/15 | measurable benefit |
| D1-s | D1-s@Y-1 | D1-s@Y-0 | 0.431 [0.391-0.476] | 2.596 [2.400-2.622] | 0.166 | 15/15 | measurable benefit |
| D1-s | D1-s@Y-2 | D1-s@Y-0 | 0.787 [0.736-0.869] | 2.596 [2.400-2.622] | 0.303 | 15/15 | measurable benefit |
| D1-s | D1-s@J-2 | D1-s@J-0y | 2.735 [2.561-2.890] | 27.860 [27.067-28.707] | 0.098 | 15/15 | measurable benefit |
| D1-s | D1-s@J-4 | D1-s@J-4c | 0.535 [0.491-0.578] | 3.241 [3.130-3.492] | 0.165 | 15/15 | measurable benefit |
| D2-s | D2-s@Y-1 | D2-s@Y-0 | 1.037 [0.960-1.180] | 2.532 [2.497-2.751] | 0.410 | 15/15 | measurable benefit |
| D2-s | D2-s@Y-2 | D2-s@Y-0 | 1.553 [1.369-1.663] | 2.532 [2.497-2.751] | 0.613 | 15/15 | measurable benefit |
| D2-s | D2-s@J-2 | D2-s@J-0y | 6.800 [6.742-7.300] | 27.026 [26.418-29.215] | 0.252 | 15/15 | measurable benefit |
| D2-s | D2-s@J-4 | D2-s@J-4c | 1.379 [1.356-1.486] | 3.263 [3.200-3.366] | 0.423 | 15/15 | measurable benefit |
| D3-s | D3-s@Y-1 | D3-s@Y-0 | 0.618 [0.584-0.637] | 2.741 [2.584-2.939] | 0.225 | 15/15 | measurable benefit |
| D3-s | D3-s@Y-2 | D3-s@Y-0 | 0.950 [0.821-1.033] | 2.741 [2.584-2.939] | 0.347 | 15/15 | measurable benefit |
| D3-s | D3-s@J-2 | D3-s@J-0y | 4.099 [3.994-4.234] | 28.743 [27.938-29.651] | 0.143 | 15/15 | measurable benefit |
| D3-s | D3-s@J-4 | D3-s@J-4c | 0.856 [0.809-0.962] | 3.344 [3.234-3.558] | 0.256 | 15/15 | measurable benefit |
| D4-s | D4-s@Y-1 | D4-s@Y-0 | 1.937 [1.857-2.124] | 2.736 [2.609-2.843] | 0.708 | 15/15 | measurable benefit |
| D4-s | D4-s@Y-2 | D4-s@Y-0 | 2.282 [2.154-2.632] | 2.736 [2.609-2.843] | 0.834 | 15/15 | index used, no measurable benefit |
| D4-s | D4-s@J-2 | D4-s@J-0y | 13.641 [12.462-13.966] | 27.135 [26.257-28.683] | 0.503 | 15/15 | measurable benefit |
| D4-s | D4-s@J-4 | D4-s@J-4c | 2.361 [2.271-2.467] | 3.583 [3.425-3.704] | 0.659 | 15/15 | measurable benefit |
| D5-s | D5-s@Y-1 | D5-s@Y-0 | 0.484 [0.454-0.531] | 2.422 [2.307-2.531] | 0.200 | 15/15 | measurable benefit |
| D5-s | D5-s@Y-2 | D5-s@Y-0 | 0.789 [0.755-0.846] | 2.422 [2.307-2.531] | 0.326 | 15/15 | measurable benefit |
| D5-s | D5-s@J-2 | D5-s@J-0y | 3.935 [3.563-4.145] | 27.399 [26.553-28.394] | 0.144 | 15/15 | measurable benefit |
| D5-s | D5-s@J-4 | D5-s@J-4c | 0.701 [0.668-0.785] | 3.115 [2.991-3.322] | 0.225 | 15/15 | measurable benefit |
| D6-s | D6-s@Y-1 | D6-s@Y-0 | 0.093 [0.078-0.125] | 2.738 [2.611-2.847] | 0.034 | 15/15 | measurable benefit |
| D6-s | D6-s@Y-2 | D6-s@Y-0 | 0.449 [0.365-0.514] | 2.738 [2.611-2.847] | 0.164 | 15/15 | measurable benefit |
| D6-s | D6-s@J-2 | D6-s@J-0y | 0.312 [0.280-0.329] | 29.023 [28.071-30.260] | 0.011 | 15/15 | measurable benefit |
| D6-s | D6-s@J-4 | D6-s@J-4c | 0.086 [0.071-0.108] | 3.520 [3.417-3.597] | 0.024 | 15/15 | measurable benefit |
| D7-s | D7-s@Y-1 | D7-s@Y-0 | 0.034 [0.029-0.045] | 2.539 [2.383-2.774] | 0.013 | 15/15 | measurable benefit |
| D7-s | D7-s@Y-2 | D7-s@Y-0 | 0.357 [0.343-0.493] | 2.539 [2.383-2.774] | 0.141 | 15/15 | measurable benefit |
| D7-s | D7-s@J-2 | D7-s@J-0y | 0.042 [0.039-0.059] | 27.586 [26.192-28.390] | 0.002 | 15/15 | measurable benefit |
| D7-s | D7-s@J-4 | D7-s@J-4c | 0.030 [0.027-0.047] | 3.318 [3.033-3.430] | 0.009 | 15/15 | measurable benefit |
| K1 | K1@Y-1 | K1@Y-0 | 0.105 [0.095-0.117] | 3.056 [2.838-3.435] | 0.034 | 15/15 | measurable benefit |
| K1 | K1@Y-2 | K1@Y-0 | 3.289 [3.157-3.500] | 3.056 [2.838-3.435] | 1.076 | 0/15 | not supported (operator class has no ordering operator) |
| K1 | K1@J-2 | K1@J-0y | 0.190 [0.181-0.205] | 29.544 [27.760-31.960] | 0.006 | 15/15 | measurable benefit |
| K1 | K1@J-4 | K1@J-4c | 0.110 [0.107-0.120] | 3.893 [3.704-4.161] | 0.028 | 15/15 | measurable benefit |
| K1 | K1g@G-1 | K1g@G-0 | 0.054 [0.051-0.060] | 1.481 [1.421-1.637] | 0.036 | 15/15 | measurable benefit |
| K2 | K2@Y-1 | K2@Y-0 | 0.273 [0.260-0.288] | 3.128 [2.937-3.233] | 0.087 | 15/15 | measurable benefit |
| K2 | K2@Y-2 | K2@Y-0 | 3.313 [3.167-3.372] | 3.128 [2.937-3.233] | 1.059 | 0/15 | not supported (operator class has no ordering operator) |
| K2 | K2@J-2 | K2@J-0y | 1.456 [1.394-1.482] | 29.501 [28.840-30.558] | 0.049 | 15/15 | measurable benefit |
| K2 | K2@J-4 | K2@J-4c | 0.319 [0.302-0.362] | 3.866 [3.698-4.000] | 0.083 | 15/15 | measurable benefit |
| K3 | K3@G-1 | K3@G-0 | 0.074 [0.067-0.085] | 1.648 [1.572-1.722] | 0.045 | 15/15 | measurable benefit |
| K3 | K3@G-2 | K3@G-0 | 1.720 [1.632-1.867] | 1.648 [1.572-1.722] | 1.044 | 0/15 | not supported (operator class has no ordering operator) |
| K3 | K3@G-3 | K3@G-0 | 1.800 [1.627-1.966] | 1.648 [1.572-1.722] | 1.092 | 0/15 | not supported (operator class has no ordering operator) |
| K3 | K3@J-1 | K3@J-0g | 0.167 [0.152-0.188] | 28.910 [26.308-30.730] | 0.006 | 15/15 | measurable benefit |
| K3 | K3@J-3 | K3@J-3c | 0.072 [0.068-0.086] | 2.389 [2.227-2.528] | 0.030 | 15/15 | measurable benefit |

## Class IM - index methods (execution time, session 1)

| block | A | B | A ms | B ms | B/A | result |
|---|---|---|---|---|---|---|
| B1 | B1@G-1 | B1@G-2 | 0.245 | 0.253 | 1.033 | not measurable |
| B1 | B1@G-1 | B1@G-3 | 0.245 | 0.884 | 3.608 | measurable: B1@G-1 faster |
| B1 | B1@G-2 | B1@G-3 | 0.253 | 0.884 | 3.494 | measurable: B1@G-2 faster |
| B2 | B2@G-1 | B2@G-2 | 0.254 | 0.279 | 1.098 | not measurable |
| B2 | B2@G-1 | B2@G-3 | 0.254 | 0.921 | 3.626 | measurable: B2@G-1 faster |
| B2 | B2@G-2 | B2@G-3 | 0.279 | 0.921 | 3.301 | measurable: B2@G-2 faster |
| B3 | B3@G-1 | B3@G-2 | 1.056 | 0.954 | 0.903 | not measurable |
| B3 | B3@G-1 | B3@G-3 | 1.056 | 1.150 | 1.089 | not measurable |
| B3 | B3@G-2 | B3@G-3 | 0.954 | 1.150 | 1.205 | measurable: B3@G-2 faster |
| B4 | B4@G-1 | B4@G-2 | 2.528 | 2.354 | 0.931 | not measurable |
| B4 | B4@G-1 | B4@G-3 | 2.528 | 1.740 | 0.688 | measurable: B4@G-3 faster |
| B4 | B4@G-2 | B4@G-3 | 2.354 | 1.740 | 0.739 | measurable: B4@G-3 faster |
| B5 | B5@G-1 | B5@G-2 | 0.038 | 0.067 | 1.763 | measurable: B5@G-1 faster; below 0.1 ms: confirmed in session 2 |
| B5 | B5@G-1 | B5@G-3 | 0.038 | 1.504 | 39.579 | measurable: B5@G-1 faster; below 0.1 ms: confirmed in session 2 |
| B5 | B5@G-2 | B5@G-3 | 0.067 | 1.504 | 22.448 | measurable: B5@G-2 faster; below 0.1 ms: confirmed in session 2 |
| B6 | B6@G-1 | B6@G-2 | 0.024 | 0.042 | 1.750 | measurable: B6@G-1 faster; below 0.1 ms: confirmed in session 2 |
| B6 | B6@G-1 | B6@G-3 | 0.024 | 0.797 | 33.208 | measurable: B6@G-1 faster; below 0.1 ms: confirmed in session 2 |
| B6 | B6@G-2 | B6@G-3 | 0.042 | 0.797 | 18.976 | measurable: B6@G-2 faster; below 0.1 ms: confirmed in session 2 |
| D1 | D1@Y-1 | D1@Y-2 | 0.438 | 0.789 | 1.801 | measurable: D1@Y-1 faster |
| D2 | D2@Y-1 | D2@Y-2 | 1.146 | 1.519 | 1.325 | measurable: D2@Y-1 faster |
| D3 | D3@Y-1 | D3@Y-2 | 0.599 | 0.930 | 1.553 | measurable: D3@Y-1 faster |
| D4 | D4@Y-1 | D4@Y-2 | 1.847 | 2.259 | 1.223 | measurable: D4@Y-1 faster |
| D5 | D5@Y-1 | D5@Y-2 | 1.360 | 1.632 | 1.200 | not measurable |
| D6 | D6@Y-1 | D6@Y-2 | 0.116 | 0.448 | 3.862 | measurable: D6@Y-1 faster |
| D7 | D7@Y-1 | D7@Y-2 | 0.042 | 0.419 | 9.976 | measurable: D7@Y-1 faster; below 0.1 ms: confirmed in session 2 |
| D1-s | D1-s@Y-1 | D1-s@Y-2 | 0.431 | 0.787 | 1.826 | measurable: D1-s@Y-1 faster |
| D2-s | D2-s@Y-1 | D2-s@Y-2 | 1.037 | 1.553 | 1.498 | measurable: D2-s@Y-1 faster |
| D3-s | D3-s@Y-1 | D3-s@Y-2 | 0.618 | 0.950 | 1.537 | measurable: D3-s@Y-1 faster |
| D4-s | D4-s@Y-1 | D4-s@Y-2 | 1.937 | 2.282 | 1.178 | measurable: D4-s@Y-1 faster |
| D5-s | D5-s@Y-1 | D5-s@Y-2 | 0.484 | 0.789 | 1.630 | measurable: D5-s@Y-1 faster |
| D6-s | D6-s@Y-1 | D6-s@Y-2 | 0.093 | 0.449 | 4.828 | measurable: D6-s@Y-1 faster; below 0.1 ms: confirmed in session 2 |
| D7-s | D7-s@Y-1 | D7-s@Y-2 | 0.034 | 0.357 | 10.500 | measurable: D7-s@Y-1 faster; below 0.1 ms: confirmed in session 2 |
| K1 | K1@Y-1 | K1@Y-2 | 0.105 | 3.289 | 31.324 | measurable: K1@Y-1 faster |
| K2 | K2@Y-1 | K2@Y-2 | 0.273 | 3.313 | 12.136 | measurable: K2@Y-1 faster |
| K3 | K3@G-1 | K3@G-2 | 0.074 | 1.720 | 23.243 | measurable: K3@G-1 faster; below 0.1 ms: confirmed in session 2 |
| K3 | K3@G-1 | K3@G-3 | 0.074 | 1.800 | 24.324 | measurable: K3@G-1 faster; below 0.1 ms: confirmed in session 2 |
| K3 | K3@G-2 | K3@G-3 | 1.720 | 1.800 | 1.047 | not measurable |

## Class F - flat vs JSONB, same type and index (execution time, session 1)

| block | A | B | A ms | B ms | B/A | result |
|---|---|---|---|---|---|---|
| B1 | B1@G-1 | B1@J-3 | 0.245 | 0.422 | 1.722 | measurable: B1@G-1 faster |
| B1 | B1@G-0 | B1@J-3c | 0.834 | 1.501 | 1.800 | measurable: B1@G-0 faster |
| B2 | B2@G-1 | B2@J-3 | 0.254 | 0.419 | 1.650 | measurable: B2@G-1 faster |
| B2 | B2@G-0 | B2@J-3c | 0.851 | 1.502 | 1.765 | measurable: B2@G-0 faster |
| B3 | B3@G-1 | B3@J-3 | 1.056 | 1.325 | 1.255 | measurable: B3@G-1 faster |
| B3 | B3@G-0 | B3@J-3c | 1.132 | 1.799 | 1.589 | measurable: B3@G-0 faster |
| B4 | B4@G-1 | B4@J-3 | 2.528 | 2.633 | 1.042 | not measurable |
| B4 | B4@G-0 | B4@J-3c | 1.612 | 2.374 | 1.473 | measurable: B4@G-0 faster |
| B5 | B5@G-1 | B5@J-3 | 0.038 | 0.038 | 1.000 | not measurable; below 0.1 ms: confirmed in session 2 |
| B5 | B5@G-0 | B5@J-3c | 1.235 | 2.041 | 1.653 | measurable: B5@G-0 faster |
| B6 | B6@G-1 | B6@J-3 | 0.024 | 0.024 | 1.000 | not measurable; below 0.1 ms: confirmed in session 2 |
| B6 | B6@G-0 | B6@J-3c | 0.754 | 1.391 | 1.845 | measurable: B6@G-0 faster |
| D1 | D1@Y-1 | D1@J-4 | 0.438 | 0.560 | 1.279 | measurable: D1@Y-1 faster |
| D1 | D1@Y-0 | D1@J-4c | 7.745 | 8.519 | 1.100 | not measurable |
| D2 | D2@Y-1 | D2@J-4 | 1.146 | 1.487 | 1.298 | measurable: D2@Y-1 faster |
| D2 | D2@Y-0 | D2@J-4c | 7.290 | 7.867 | 1.079 | not measurable |
| D3 | D3@Y-1 | D3@J-4 | 0.599 | 0.911 | 1.521 | measurable: D3@Y-1 faster |
| D3 | D3@Y-0 | D3@J-4c | 7.437 | 8.663 | 1.165 | measurable: D3@Y-0 faster |
| D4 | D4@Y-1 | D4@J-4 | 1.847 | 2.556 | 1.384 | measurable: D4@Y-1 faster |
| D4 | D4@Y-0 | D4@J-4c | 5.657 | 6.876 | 1.215 | measurable: D4@Y-0 faster |
| D5 | D5@Y-1 | D5@J-4 | 1.360 | 1.625 | 1.195 | measurable: D5@Y-1 faster |
| D5 | D5@Y-0 | D5@J-4c | 8.189 | 9.136 | 1.116 | measurable: D5@Y-0 faster |
| D6 | D6@Y-1 | D6@J-4 | 0.116 | 0.098 | 0.845 | not measurable (session 2 does not confirm) |
| D6 | D6@Y-0 | D6@J-4c | 8.168 | 9.100 | 1.114 | measurable: D6@Y-0 faster |
| D7 | D7@Y-1 | D7@J-4 | 0.042 | 0.035 | 0.833 | not measurable; below 0.1 ms: confirmed in session 2 |
| D7 | D7@Y-0 | D7@J-4c | 4.331 | 5.157 | 1.191 | measurable: D7@Y-0 faster |
| D1-s | D1-s@Y-1 | D1-s@J-4 | 0.431 | 0.535 | 1.241 | measurable: D1-s@Y-1 faster |
| D1-s | D1-s@Y-0 | D1-s@J-4c | 2.596 | 3.241 | 1.248 | measurable: D1-s@Y-0 faster |
| D2-s | D2-s@Y-1 | D2-s@J-4 | 1.037 | 1.379 | 1.330 | measurable: D2-s@Y-1 faster |
| D2-s | D2-s@Y-0 | D2-s@J-4c | 2.532 | 3.263 | 1.289 | measurable: D2-s@Y-0 faster |
| D3-s | D3-s@Y-1 | D3-s@J-4 | 0.618 | 0.856 | 1.385 | measurable: D3-s@Y-1 faster |
| D3-s | D3-s@Y-0 | D3-s@J-4c | 2.741 | 3.344 | 1.220 | measurable: D3-s@Y-0 faster |
| D4-s | D4-s@Y-1 | D4-s@J-4 | 1.937 | 2.361 | 1.219 | measurable: D4-s@Y-1 faster |
| D4-s | D4-s@Y-0 | D4-s@J-4c | 2.736 | 3.583 | 1.310 | measurable: D4-s@Y-0 faster |
| D5-s | D5-s@Y-1 | D5-s@J-4 | 0.484 | 0.701 | 1.448 | measurable: D5-s@Y-1 faster |
| D5-s | D5-s@Y-0 | D5-s@J-4c | 2.422 | 3.115 | 1.286 | measurable: D5-s@Y-0 faster |
| D6-s | D6-s@Y-1 | D6-s@J-4 | 0.093 | 0.086 | 0.925 | not measurable (session 2 does not confirm) |
| D6-s | D6-s@Y-0 | D6-s@J-4c | 2.738 | 3.520 | 1.286 | measurable: D6-s@Y-0 faster |
| D7-s | D7-s@Y-1 | D7-s@J-4 | 0.034 | 0.030 | 0.882 | not measurable; below 0.1 ms: confirmed in session 2 |
| D7-s | D7-s@Y-0 | D7-s@J-4c | 2.539 | 3.318 | 1.307 | measurable: D7-s@Y-0 faster |
| K1 | K1@Y-1 | K1@J-4 | 0.105 | 0.110 | 1.048 | not measurable |
| K1 | K1@Y-0 | K1@J-4c | 3.056 | 3.893 | 1.274 | measurable: K1@Y-0 faster |
| K2 | K2@Y-1 | K2@J-4 | 0.273 | 0.319 | 1.168 | measurable: K2@Y-1 faster |
| K2 | K2@Y-0 | K2@J-4c | 3.128 | 3.866 | 1.236 | measurable: K2@Y-0 faster |
| K3 | K3@G-1 | K3@J-3 | 0.074 | 0.072 | 0.973 | not measurable; below 0.1 ms: confirmed in session 2 |
| K3 | K3@G-0 | K3@J-3c | 1.648 | 2.389 | 1.450 | measurable: K3@G-0 faster |

## Class J - JSONB storage forms and construction (execution time, session 1)

| block | A | B | A ms | B ms | B/A | result |
|---|---|---|---|---|---|---|
| B1 | B1@J-1 | B1@J-3 | 2.500 | 0.422 | 0.169 | measurable: B1@J-3 faster |
| B1 | B1@J-0g | B1@J-3c | 24.598 | 1.501 | 0.061 | measurable: B1@J-3c faster |
| B2 | B2@J-1 | B2@J-3 | 2.490 | 0.419 | 0.168 | measurable: B2@J-3 faster |
| B2 | B2@J-0g | B2@J-3c | 25.293 | 1.502 | 0.059 | measurable: B2@J-3c faster |
| B3 | B3@J-1 | B3@J-3 | 8.877 | 1.325 | 0.149 | measurable: B3@J-3 faster |
| B3 | B3@J-0g | B3@J-3c | 25.076 | 1.799 | 0.072 | measurable: B3@J-3c faster |
| B4 | B4@J-1 | B4@J-3 | 23.150 | 2.633 | 0.114 | measurable: B4@J-3 faster |
| B4 | B4@J-0g | B4@J-3c | 26.417 | 2.374 | 0.090 | measurable: B4@J-3c faster |
| B5 | B5@J-1 | B5@J-3 | 0.050 | 0.038 | 0.760 | measurable: B5@J-3 faster; below 0.1 ms: confirmed in session 2 |
| B5 | B5@J-0g | B5@J-3c | 46.525 | 2.041 | 0.044 | measurable: B5@J-3c faster |
| B6 | B6@J-1 | B6@J-3 | 0.032 | 0.024 | 0.750 | measurable: B6@J-3 faster; below 0.1 ms: confirmed in session 2 |
| B6 | B6@J-0g | B6@J-3c | 24.026 | 1.391 | 0.058 | measurable: B6@J-3c faster |
| D1 | D1@J-2 | D1@J-4 | 2.803 | 0.560 | 0.200 | measurable: D1@J-4 faster |
| D1 | D1@J-0y | D1@J-4c | 33.305 | 8.519 | 0.256 | measurable: D1@J-4c faster |
| D2 | D2@J-2 | D2@J-4 | 6.950 | 1.487 | 0.214 | measurable: D2@J-4 faster |
| D2 | D2@J-0y | D2@J-4c | 32.492 | 7.867 | 0.242 | measurable: D2@J-4c faster |
| D3 | D3@J-2 | D3@J-4 | 4.020 | 0.911 | 0.227 | measurable: D3@J-4 faster |
| D3 | D3@J-0y | D3@J-4c | 31.665 | 8.663 | 0.274 | measurable: D3@J-4c faster |
| D4 | D4@J-2 | D4@J-4 | 13.222 | 2.556 | 0.193 | measurable: D4@J-4 faster |
| D4 | D4@J-0y | D4@J-4c | 30.961 | 6.876 | 0.222 | measurable: D4@J-4c faster |
| D5 | D5@J-2 | D5@J-4 | 4.736 | 1.625 | 0.343 | measurable: D5@J-4 faster |
| D5 | D5@J-0y | D5@J-4c | 33.550 | 9.136 | 0.272 | measurable: D5@J-4c faster |
| D6 | D6@J-2 | D6@J-4 | 0.329 | 0.098 | 0.298 | measurable: D6@J-4 faster; below 0.1 ms: confirmed in session 2 |
| D6 | D6@J-0y | D6@J-4c | 33.963 | 9.100 | 0.268 | measurable: D6@J-4c faster |
| D7 | D7@J-2 | D7@J-4 | 0.057 | 0.035 | 0.614 | not measurable (session 2 does not confirm) |
| D7 | D7@J-0y | D7@J-4c | 30.254 | 5.157 | 0.170 | measurable: D7@J-4c faster |
| D1-s | D1-s@J-2 | D1-s@J-4 | 2.735 | 0.535 | 0.196 | measurable: D1-s@J-4 faster |
| D1-s | D1-s@J-0y | D1-s@J-4c | 27.860 | 3.241 | 0.116 | measurable: D1-s@J-4c faster |
| D2-s | D2-s@J-2 | D2-s@J-4 | 6.800 | 1.379 | 0.203 | measurable: D2-s@J-4 faster |
| D2-s | D2-s@J-0y | D2-s@J-4c | 27.026 | 3.263 | 0.121 | measurable: D2-s@J-4c faster |
| D3-s | D3-s@J-2 | D3-s@J-4 | 4.099 | 0.856 | 0.209 | measurable: D3-s@J-4 faster |
| D3-s | D3-s@J-0y | D3-s@J-4c | 28.743 | 3.344 | 0.116 | measurable: D3-s@J-4c faster |
| D4-s | D4-s@J-2 | D4-s@J-4 | 13.641 | 2.361 | 0.173 | measurable: D4-s@J-4 faster |
| D4-s | D4-s@J-0y | D4-s@J-4c | 27.135 | 3.583 | 0.132 | measurable: D4-s@J-4c faster |
| D5-s | D5-s@J-2 | D5-s@J-4 | 3.935 | 0.701 | 0.178 | measurable: D5-s@J-4 faster |
| D5-s | D5-s@J-0y | D5-s@J-4c | 27.399 | 3.115 | 0.114 | measurable: D5-s@J-4c faster |
| D6-s | D6-s@J-2 | D6-s@J-4 | 0.312 | 0.086 | 0.276 | measurable: D6-s@J-4 faster; below 0.1 ms: confirmed in session 2 |
| D6-s | D6-s@J-0y | D6-s@J-4c | 29.023 | 3.520 | 0.121 | measurable: D6-s@J-4c faster |
| D7-s | D7-s@J-2 | D7-s@J-4 | 0.042 | 0.030 | 0.714 | not measurable; below 0.1 ms: confirmed in session 2 |
| D7-s | D7-s@J-0y | D7-s@J-4c | 27.586 | 3.318 | 0.120 | measurable: D7-s@J-4c faster |
| K1 | K1@J-2 | K1@J-4 | 0.190 | 0.110 | 0.579 | measurable: K1@J-4 faster |
| K1 | K1@J-0y | K1@J-4c | 29.544 | 3.893 | 0.132 | measurable: K1@J-4c faster |
| K2 | K2@J-2 | K2@J-4 | 1.456 | 0.319 | 0.219 | measurable: K2@J-4 faster |
| K2 | K2@J-0y | K2@J-4c | 29.501 | 3.866 | 0.131 | measurable: K2@J-4c faster |
| K3 | K3@J-1 | K3@J-3 | 0.167 | 0.072 | 0.431 | measurable: K3@J-3 faster; below 0.1 ms: confirmed in session 2 |
| K3 | K3@J-0g | K3@J-3c | 28.910 | 2.389 | 0.083 | measurable: K3@J-3c faster |
| P | P4@J-0y | P1@Y-0 | 36.468 | 10.226 | 0.280 | measurable: P1@Y-0 faster |
| P | P4@J-0y | P3@N-0 | 36.468 | 14.413 | 0.395 | measurable: P3@N-0 faster |
| P | P3@N-0 | P1@Y-0 | 14.413 | 10.226 | 0.709 | measurable: P1@Y-0 faster |

## Class GG - geometry vs geography / method (execution time, session 1)

| block | A | B | A ms | B ms | B/A | result |
|---|---|---|---|---|---|---|
| D1 | D1@Y-1 | MD1@G-1 | 0.438 | 0.597 | 1.363 | measurable: D1@Y-1 faster |
| D1 | D1@Y-0 | MD1@G-0 | 7.745 | 1.147 | 0.148 | measurable: MD1@G-0 faster |
| D2 | D2@Y-1 | MD2@G-1 | 1.146 | 1.798 | 1.569 | measurable: D2@Y-1 faster |
| D2 | D2@Y-0 | MD2@G-0 | 7.290 | 2.111 | 0.290 | measurable: MD2@G-0 faster |
| D6 | D6@Y-1 | MD6@G-1 | 0.116 | 0.071 | 0.612 | measurable: MD6@G-1 faster; below 0.1 ms: confirmed in session 2 |
| D6 | D6@Y-0 | MD6@G-0 | 8.168 | 0.648 | 0.079 | measurable: MD6@G-0 faster |
| K1 | K1@Y-1 | K1g@G-1 | 0.105 | 0.054 | 0.514 | measurable: K1g@G-1 faster; below 0.1 ms: confirmed in session 2 |
| K1 | K1@Y-0 | K1g@G-0 | 3.056 | 1.481 | 0.485 | measurable: K1g@G-0 faster |
| P | P1@Y-0 | P2@Y-0 | 10.226 | 5.188 | 0.507 | measurable: P2@Y-0 faster |

## Class NB - numeric B-tree vs spatial (execution time, session 1)

| block | A | B | A ms | B ms | B/A | result |
|---|---|---|---|---|---|---|
| B1 | B1@N-1 | B1@G-1 | 0.181 | 0.245 | 1.354 | measurable: B1@N-1 faster |
| B1 | B1@N-0 | B1@G-0 | 0.569 | 0.834 | 1.466 | measurable: B1@N-0 faster |
| B2 | B2@N-1 | B2@G-1 | 0.268 | 0.254 | 0.948 | not measurable |
| B2 | B2@N-0 | B2@G-0 | 0.614 | 0.851 | 1.386 | measurable: B2@N-0 faster |
| B3 | B3@N-1 | B3@G-1 | 0.526 | 1.056 | 2.008 | measurable: B3@N-1 faster |
| B3 | B3@N-0 | B3@G-0 | 0.869 | 1.132 | 1.303 | measurable: B3@N-0 faster |
| B4 | B4@N-1 | B4@G-1 | 1.275 | 2.528 | 1.983 | measurable: B4@N-1 faster |
| B4 | B4@N-0 | B4@G-0 | 1.224 | 1.612 | 1.317 | measurable: B4@N-0 faster |
| B5 | B5@N-1 | B5@G-1 | 0.912 | 0.038 | 0.042 | measurable: B5@G-1 faster; below 0.1 ms: confirmed in session 2 |
| B5 | B5@N-0 | B5@G-0 | 0.902 | 1.235 | 1.369 | measurable: B5@N-0 faster |
| B6 | B6@N-1 | B6@G-1 | 0.018 | 0.024 | 1.333 | measurable: B6@N-1 faster; below 0.1 ms: confirmed in session 2 |
| B6 | B6@N-0 | B6@G-0 | 0.434 | 0.754 | 1.737 | measurable: B6@N-0 faster |

## Plan shapes (session 1, measured runs)

| series | plan shape | shared hit |
|---|---|---|
| B1@G-0 | Seq Scan on flat_geom | 39 |
| B1@G-1 | Bitmap Heap Scan on flat_geom_gist [Bitmap Index Scan using flat_geom_gist_idx] | 42 |
| B1@G-2 | Bitmap Heap Scan on flat_geom_spgist [Bitmap Index Scan using flat_geom_spgist_idx] | 45 |
| B1@G-3 | Seq Scan on flat_geom_brin | 39 |
| B1@J-0g | Seq Scan on jsonb_doc | 981 |
| B1@J-1 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geom_gist_idx] | 342 |
| B1@J-3 | Bitmap Heap Scan on jsonb_geom_gist [Bitmap Index Scan using jsonb_geom_gist_idx] | 331 |
| B1@J-3c | Seq Scan on jsonb_geom | 879 |
| B1@N-0 | Seq Scan on flat_numeric | 31 |
| B1@N-1 | Bitmap Heap Scan on flat_numeric_btree [Bitmap Index Scan using flat_numeric_btree_lat_lon_idx] | 35 |
| B2@G-0 | Seq Scan on flat_geom | 39 |
| B2@G-1 | Bitmap Heap Scan on flat_geom_gist [Bitmap Index Scan using flat_geom_gist_idx] | 43 |
| B2@G-2 | Bitmap Heap Scan on flat_geom_spgist [Bitmap Index Scan using flat_geom_spgist_idx] | 57 |
| B2@G-3 | Seq Scan on flat_geom_brin | 39 |
| B2@J-0g | Seq Scan on jsonb_doc | 981 |
| B2@J-1 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geom_gist_idx] | 336 |
| B2@J-3 | Bitmap Heap Scan on jsonb_geom_gist [Bitmap Index Scan using jsonb_geom_gist_idx] | 351 |
| B2@J-3c | Seq Scan on jsonb_geom | 879 |
| B2@N-0 | Seq Scan on flat_numeric | 31 |
| B2@N-1 | Bitmap Heap Scan on flat_numeric_btree [Bitmap Index Scan using flat_numeric_btree_lat_lon_idx] | 37 |
| B3@G-0 | Seq Scan on flat_geom | 39 |
| B3@G-1 | Index Scan using flat_geom_gist_idx | 1556 |
| B3@G-2 | Index Scan using flat_geom_spgist_idx | 870 |
| B3@G-3 | Seq Scan on flat_geom_brin | 39 |
| B3@J-0g | Seq Scan on jsonb_doc | 981 |
| B3@J-1 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geom_gist_idx] | 832 |
| B3@J-3 | Bitmap Heap Scan on jsonb_geom_gist [Bitmap Index Scan using jsonb_geom_gist_idx] | 765 |
| B3@J-3c | Seq Scan on jsonb_geom | 879 |
| B3@N-0 | Seq Scan on flat_numeric | 31 |
| B3@N-1 | Bitmap Heap Scan on flat_numeric_btree [Bitmap Index Scan using flat_numeric_btree_lat_lon_idx] | 40 |
| B4@G-0 | Seq Scan on flat_geom | 39 |
| B4@G-1 | Index Scan using flat_geom_gist_idx | 3828 |
| B4@G-2 | Index Scan using flat_geom_spgist_idx | 2134 |
| B4@G-3 | Seq Scan on flat_geom_brin | 39 |
| B4@J-0g | Seq Scan on jsonb_doc | 981 |
| B4@J-1 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geom_gist_idx] | 1002 |
| B4@J-3 | Bitmap Heap Scan on jsonb_geom_gist [Bitmap Index Scan using jsonb_geom_gist_idx] | 900 |
| B4@J-3c | Seq Scan on jsonb_geom | 879 |
| B4@N-0 | Seq Scan on flat_numeric | 31 |
| B4@N-1 | Seq Scan on flat_numeric_btree | 31 |
| B5@G-0 | Seq Scan on flat_geom | 39 |
| B5@G-1 | Bitmap Heap Scan on flat_geom_gist [BitmapOr [Bitmap Index Scan using flat_geom_gist_idx; Bitmap Index Scan using flat_geom_gist_idx]] | 4 |
| B5@G-2 | Bitmap Heap Scan on flat_geom_spgist [BitmapOr [Bitmap Index Scan using flat_geom_spgist_idx; Bitmap Index Scan using flat_geom_spgist_idx]] | 20 |
| B5@G-3 | Bitmap Heap Scan on flat_geom_brin [BitmapOr [Bitmap Index Scan using flat_geom_brin_idx; Bitmap Index Scan using flat_geom_brin_idx]] | 43 |
| B5@J-0g | Seq Scan on jsonb_doc | 981 |
| B5@J-1 | Bitmap Heap Scan on jsonb_doc_expr [BitmapOr [Bitmap Index Scan using jsonb_doc_expr_geom_gist_idx; Bitmap Index Scan using jsonb_doc_expr_geom_gist_idx]] | 4 |
| B5@J-3 | Bitmap Heap Scan on jsonb_geom_gist [BitmapOr [Bitmap Index Scan using jsonb_geom_gist_idx; Bitmap Index Scan using jsonb_geom_gist_idx]] | 4 |
| B5@J-3c | Seq Scan on jsonb_geom | 879 |
| B5@N-0 | Seq Scan on flat_numeric | 31 |
| B5@N-1 | Seq Scan on flat_numeric_btree | 31 |
| B6@G-0 | Seq Scan on flat_geom | 39 |
| B6@G-1 | Index Scan using flat_geom_gist_idx | 3 |
| B6@G-2 | Index Scan using flat_geom_spgist_idx | 13 |
| B6@G-3 | Seq Scan on flat_geom_brin | 39 |
| B6@J-0g | Seq Scan on jsonb_doc | 981 |
| B6@J-1 | Index Scan using jsonb_doc_expr_geom_gist_idx | 3 |
| B6@J-3 | Index Scan using jsonb_geom_gist_idx | 3 |
| B6@J-3c | Seq Scan on jsonb_geom | 879 |
| B6@N-0 | Seq Scan on flat_numeric | 31 |
| B6@N-1 | Bitmap Heap Scan on flat_numeric_btree [Bitmap Index Scan using flat_numeric_btree_lat_lon_idx] | 3 |
| D1@J-0y | Seq Scan on jsonb_doc | 981 |
| D1@J-2 | Index Scan using jsonb_doc_expr_geog_gist_idx | 395 |
| D1@J-4 | Index Scan using jsonb_geog_gist_idx | 393 |
| D1@J-4c | Seq Scan on jsonb_geog | 879 |
| D1@Y-0 | Seq Scan on flat_geog | 39 |
| D1@Y-1 | Index Scan using flat_geog_gist_idx | 149 |
| D1@Y-2 | Index Scan using flat_geog_spgist_idx | 425 |
| MD1@G-0 | Seq Scan on flat_geom | 39 |
| MD1@G-1 | Bitmap Heap Scan on flat_geom_gist [Bitmap Index Scan using flat_geom_gist_idx] | 42 |
| D1-s@J-0y | Seq Scan on jsonb_doc | 981 |
| D1-s@J-2 | Index Scan using jsonb_doc_expr_geog_gist_idx | 395 |
| D1-s@J-4 | Index Scan using jsonb_geog_gist_idx | 393 |
| D1-s@J-4c | Seq Scan on jsonb_geog | 879 |
| D1-s@Y-0 | Seq Scan on flat_geog | 39 |
| D1-s@Y-1 | Index Scan using flat_geog_gist_idx | 149 |
| D1-s@Y-2 | Index Scan using flat_geog_spgist_idx | 425 |
| D2@J-0y | Seq Scan on jsonb_doc | 981 |
| D2@J-2 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geog_gist_idx] | 710 |
| D2@J-4 | Bitmap Heap Scan on jsonb_geog_gist [Bitmap Index Scan using jsonb_geog_gist_idx] | 682 |
| D2@J-4c | Seq Scan on jsonb_geog | 879 |
| D2@Y-0 | Seq Scan on flat_geog | 39 |
| D2@Y-1 | Index Scan using flat_geog_gist_idx | 418 |
| D2@Y-2 | Index Scan using flat_geog_spgist_idx | 951 |
| MD2@G-0 | Seq Scan on flat_geom | 39 |
| MD2@G-1 | Index Scan using flat_geom_gist_idx | 1080 |
| D2-s@J-0y | Seq Scan on jsonb_doc | 981 |
| D2-s@J-2 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geog_gist_idx] | 710 |
| D2-s@J-4 | Bitmap Heap Scan on jsonb_geog_gist [Bitmap Index Scan using jsonb_geog_gist_idx] | 682 |
| D2-s@J-4c | Seq Scan on jsonb_geog | 879 |
| D2-s@Y-0 | Seq Scan on flat_geog | 39 |
| D2-s@Y-1 | Index Scan using flat_geog_gist_idx | 418 |
| D2-s@Y-2 | Index Scan using flat_geog_spgist_idx | 951 |
| D3@J-0y | Seq Scan on jsonb_doc | 981 |
| D3@J-2 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geog_gist_idx] | 463 |
| D3@J-4 | Bitmap Heap Scan on jsonb_geog_gist [Bitmap Index Scan using jsonb_geog_gist_idx] | 463 |
| D3@J-4c | Seq Scan on jsonb_geog | 879 |
| D3@Y-0 | Seq Scan on flat_geog | 39 |
| D3@Y-1 | Bitmap Heap Scan on flat_geog_gist [Bitmap Index Scan using flat_geog_gist_idx] | 45 |
| D3@Y-2 | Bitmap Heap Scan on flat_geog_spgist [Bitmap Index Scan using flat_geog_spgist_idx] | 188 |
| D3-s@J-0y | Seq Scan on jsonb_doc | 981 |
| D3-s@J-2 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geog_gist_idx] | 463 |
| D3-s@J-4 | Bitmap Heap Scan on jsonb_geog_gist [Bitmap Index Scan using jsonb_geog_gist_idx] | 463 |
| D3-s@J-4c | Seq Scan on jsonb_geog | 879 |
| D3-s@Y-0 | Seq Scan on flat_geog | 39 |
| D3-s@Y-1 | Bitmap Heap Scan on flat_geog_gist [Bitmap Index Scan using flat_geog_gist_idx] | 45 |
| D3-s@Y-2 | Bitmap Heap Scan on flat_geog_spgist [Bitmap Index Scan using flat_geog_spgist_idx] | 188 |
| D4@J-0y | Seq Scan on jsonb_doc | 981 |
| D4@J-2 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geog_gist_idx] | 936 |
| D4@J-4 | Bitmap Heap Scan on jsonb_geog_gist [Bitmap Index Scan using jsonb_geog_gist_idx] | 852 |
| D4@J-4c | Seq Scan on jsonb_geog | 879 |
| D4@Y-0 | Seq Scan on flat_geog | 39 |
| D4@Y-1 | Index Scan using flat_geog_gist_idx | 685 |
| D4@Y-2 | Index Scan using flat_geog_spgist_idx | 1552 |
| D4-s@J-0y | Seq Scan on jsonb_doc | 981 |
| D4-s@J-2 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geog_gist_idx] | 936 |
| D4-s@J-4 | Bitmap Heap Scan on jsonb_geog_gist [Bitmap Index Scan using jsonb_geog_gist_idx] | 852 |
| D4-s@J-4c | Seq Scan on jsonb_geog | 879 |
| D4-s@Y-0 | Seq Scan on flat_geog | 39 |
| D4-s@Y-1 | Index Scan using flat_geog_gist_idx | 685 |
| D4-s@Y-2 | Index Scan using flat_geog_spgist_idx | 1552 |
| D5@J-0y | Seq Scan on jsonb_doc | 981 |
| D5@J-2 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geog_gist_idx] | 455 |
| D5@J-4 | Bitmap Heap Scan on jsonb_geog_gist [Bitmap Index Scan using jsonb_geog_gist_idx] | 439 |
| D5@J-4c | Seq Scan on jsonb_geog | 879 |
| D5@Y-0 | Seq Scan on flat_geog | 39 |
| D5@Y-1 | Bitmap Heap Scan on flat_geog_gist [Bitmap Index Scan using flat_geog_gist_idx] | 46 |
| D5@Y-2 | Bitmap Heap Scan on flat_geog_spgist [Bitmap Index Scan using flat_geog_spgist_idx] | 188 |
| D5-s@J-0y | Seq Scan on jsonb_doc | 981 |
| D5-s@J-2 | Bitmap Heap Scan on jsonb_doc_expr [Bitmap Index Scan using jsonb_doc_expr_geog_gist_idx] | 455 |
| D5-s@J-4 | Bitmap Heap Scan on jsonb_geog_gist [Bitmap Index Scan using jsonb_geog_gist_idx] | 439 |
| D5-s@J-4c | Seq Scan on jsonb_geog | 879 |
| D5-s@Y-0 | Seq Scan on flat_geog | 39 |
| D5-s@Y-1 | Bitmap Heap Scan on flat_geog_gist [Bitmap Index Scan using flat_geog_gist_idx] | 46 |
| D5-s@Y-2 | Bitmap Heap Scan on flat_geog_spgist [Bitmap Index Scan using flat_geog_spgist_idx] | 188 |
| D6@J-0y | Seq Scan on jsonb_doc | 981 |
| D6@J-2 | Index Scan using jsonb_doc_expr_geog_gist_idx | 30 |
| D6@J-4 | Index Scan using jsonb_geog_gist_idx | 31 |
| D6@J-4c | Seq Scan on jsonb_geog | 879 |
| D6@Y-0 | Seq Scan on flat_geog | 39 |
| D6@Y-1 | Index Scan using flat_geog_gist_idx | 26 |
| D6@Y-2 | Index Scan using flat_geog_spgist_idx | 173 |
| MD6@G-0 | Seq Scan on flat_geom | 39 |
| MD6@G-1 | Index Scan using flat_geom_gist_idx | 25 |
| D6-s@J-0y | Seq Scan on jsonb_doc | 981 |
| D6-s@J-2 | Index Scan using jsonb_doc_expr_geog_gist_idx | 30 |
| D6-s@J-4 | Index Scan using jsonb_geog_gist_idx | 31 |
| D6-s@J-4c | Seq Scan on jsonb_geog | 879 |
| D6-s@Y-0 | Seq Scan on flat_geog | 39 |
| D6-s@Y-1 | Index Scan using flat_geog_gist_idx | 26 |
| D6-s@Y-2 | Index Scan using flat_geog_spgist_idx | 173 |
| D7@J-0y | Seq Scan on jsonb_doc | 981 |
| D7@J-2 | Index Scan using jsonb_doc_expr_geog_gist_idx | 3 |
| D7@J-4 | Index Scan using jsonb_geog_gist_idx | 3 |
| D7@J-4c | Seq Scan on jsonb_geog | 879 |
| D7@Y-0 | Seq Scan on flat_geog | 39 |
| D7@Y-1 | Index Scan using flat_geog_gist_idx | 3 |
| D7@Y-2 | Index Scan using flat_geog_spgist_idx | 150 |
| D7-s@J-0y | Seq Scan on jsonb_doc | 981 |
| D7-s@J-2 | Index Scan using jsonb_doc_expr_geog_gist_idx | 3 |
| D7-s@J-4 | Index Scan using jsonb_geog_gist_idx | 3 |
| D7-s@J-4c | Seq Scan on jsonb_geog | 879 |
| D7-s@Y-0 | Seq Scan on flat_geog | 39 |
| D7-s@Y-1 | Index Scan using flat_geog_gist_idx | 3 |
| D7-s@Y-2 | Index Scan using flat_geog_spgist_idx | 150 |
| K1@J-0y | Limit [Sort [Seq Scan on jsonb_doc]] | 981 |
| K1@J-2 | Limit [Index Scan using jsonb_doc_expr_geog_gist_idx] | 14 |
| K1@J-4 | Limit [Index Scan using jsonb_geog_gist_idx] | 14 |
| K1@J-4c | Limit [Sort [Seq Scan on jsonb_geog]] | 879 |
| K1@Y-0 | Limit [Sort [Seq Scan on flat_geog]] | 39 |
| K1@Y-1 | Limit [Index Scan using flat_geog_gist_idx] | 13 |
| K1@Y-2 | Limit [Sort [Seq Scan on flat_geog_spgist]] | 39 |
| K1g@G-0 | Limit [Sort [Seq Scan on flat_geom]] | 39 |
| K1g@G-1 | Limit [Index Scan using flat_geom_gist_idx] | 13 |
| K2@J-0y | Limit [Sort [Seq Scan on jsonb_doc]] | 981 |
| K2@J-2 | Limit [Index Scan using jsonb_doc_expr_geog_gist_idx] | 103 |
| K2@J-4 | Limit [Index Scan using jsonb_geog_gist_idx] | 104 |
| K2@J-4c | Limit [Sort [Seq Scan on jsonb_geog]] | 879 |
| K2@Y-0 | Limit [Sort [Seq Scan on flat_geog]] | 39 |
| K2@Y-1 | Limit [Index Scan using flat_geog_gist_idx] | 100 |
| K2@Y-2 | Limit [Sort [Seq Scan on flat_geog_spgist]] | 39 |
| K3@G-0 | Limit [Sort [Seq Scan on flat_geom]] | 39 |
| K3@G-1 | Limit [Index Scan using flat_geom_gist_idx] | 13 |
| K3@G-2 | Limit [Sort [Seq Scan on flat_geom_spgist]] | 39 |
| K3@G-3 | Limit [Sort [Seq Scan on flat_geom_brin]] | 39 |
| K3@J-0g | Limit [Sort [Seq Scan on jsonb_doc]] | 981 |
| K3@J-1 | Limit [Index Scan using jsonb_doc_expr_geom_gist_idx] | 13 |
| K3@J-3 | Limit [Index Scan using jsonb_geom_gist_idx] | 13 |
| K3@J-3c | Limit [Sort [Seq Scan on jsonb_geom]] | 879 |
| P1@Y-0 | Seq Scan on flat_geog | 39 |
| P2@Y-0 | Seq Scan on flat_geog | 39 |
| P3@N-0 | Seq Scan on flat_numeric | 31 |
| P4@J-0y | Seq Scan on jsonb_doc | 981 |
