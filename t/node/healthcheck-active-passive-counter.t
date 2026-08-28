#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

repeat_each(1);
log_level('info');
no_root_location();
no_shuffle();

run_tests();

__DATA__

=== TEST 1: passive successes reset failures accumulated by active checks
# Both check types select their own threshold, but incr_counter stores their
# results in one counter keyed only by target identity. Each success masks away
# all failure bytes. Consequently, two active failures separated by a passive
# success never reach active.unhealthy.http_failures=2.
--- config
    location /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = assert(healthcheck.new({
                name = "test-active-passive-shared-counter",
                shm_name = "upstream-healthcheck",
                checks = {
                    active = {
                        healthy = { interval = 0, successes = 2 },
                        unhealthy = { interval = 0, http_failures = 2 },
                    },
                    passive = {
                        healthy = { successes = 2 },
                        unhealthy = { http_failures = 2 },
                    },
                },
                events_module = "resty.events",
            }))

            assert(checker:add_target("127.0.0.1", 19792, nil, true))
            ngx.sleep(0.1)

            assert(checker:report_http_status("127.0.0.1", 19792, nil, 503, "active"))
            ngx.sleep(0.1)
            assert(checker:report_http_status("127.0.0.1", 19792, nil, 200, "passive"))
            ngx.sleep(0.1)
            assert(checker:report_http_status("127.0.0.1", 19792, nil, 503, "active"))
            ngx.sleep(0.1)

            ngx.say("after active failure, passive success, active failure: ",
                    tostring(checker:get_target_status("127.0.0.1", 19792)))

            -- With no intervening success, the next active failure reaches 2/2.
            assert(checker:report_http_status("127.0.0.1", 19792, nil, 503, "active"))
            ngx.sleep(0.1)
            ngx.say("after one more consecutive active failure: ",
                    tostring(checker:get_target_status("127.0.0.1", 19792)))

            checker:stop()
        }
    }
--- request
GET /t
--- response_body
after active failure, passive success, active failure: true
after one more consecutive active failure: false
--- grep_error_log eval
qr/(?:unhealthy HTTP|healthy SUCCESS) increment \(\d\/2\)/
--- grep_error_log_out
unhealthy HTTP increment (1/2)
healthy SUCCESS increment (1/2)
unhealthy HTTP increment (1/2)
unhealthy HTTP increment (2/2)
--- no_error_log
[error]
--- timeout: 5



=== TEST 2: passive healthy successes zero preserves active failure progress
# successes=0 takes incr_counter's explicit no-op path, so the passive success
# cannot clear the failure byte and the second active failure reaches 2/2.
--- config
    location /t {
        content_by_lua_block {
            local healthcheck = require("resty.healthcheck")
            local checker = assert(healthcheck.new({
                name = "test-passive-success-disabled",
                shm_name = "upstream-healthcheck",
                checks = {
                    active = {
                        healthy = { interval = 0, successes = 2 },
                        unhealthy = { interval = 0, http_failures = 2 },
                    },
                    passive = {
                        healthy = { successes = 0 },
                        unhealthy = { http_failures = 2 },
                    },
                },
                events_module = "resty.events",
            }))

            assert(checker:add_target("127.0.0.1", 19793, nil, true))
            ngx.sleep(0.1)

            assert(checker:report_http_status("127.0.0.1", 19793, nil, 503, "active"))
            ngx.sleep(0.1)
            assert(checker:report_http_status("127.0.0.1", 19793, nil, 200, "passive"))
            ngx.sleep(0.1)
            assert(checker:report_http_status("127.0.0.1", 19793, nil, 503, "active"))
            ngx.sleep(0.1)

            ngx.say("after interleaved disabled passive success: ",
                    tostring(checker:get_target_status("127.0.0.1", 19793)))

            checker:stop()
        }
    }
--- request
GET /t
--- response_body
after interleaved disabled passive success: false
--- grep_error_log eval
qr/unhealthy HTTP increment \(\d\/2\)/
--- grep_error_log_out
unhealthy HTTP increment (1/2)
unhealthy HTTP increment (2/2)
--- no_error_log
healthy SUCCESS increment
[error]
--- timeout: 5
