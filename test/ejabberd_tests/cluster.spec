{suites, "tests", cluster_SUITE}.
{config, ["test.config"]}.
{logdir, "ct_report"}.
{ct_hooks, [ct_tty_hook, ct_mongoose_hook]}.
