// SPDX-License-Identifier: GPL-2.0
/*
 * bottle_tso: x86-style memory ordering (TSO) for the whole VM, on Apple Silicon.
 *
 * Apple's CPUs can order memory the way x86 does (total store order) when ACTLR_EL1.TSOEN
 * (bit 1) is set; Rosetta uses this on macOS. Since macOS 14.4 Apple's hypervisor lets a
 * Linux guest set the bit too, and says so with AIDR_EL1 bit 9 (Apple's own Linux patches,
 * "tso: aarch64: Expose TSO for virtualized linux on Apple Silicon", April 2024; not in
 * mainline Linux). FEX, which runs the x86 games here, otherwise makes every memory access
 * of a multithreaded x86 program ordered in software, which costs a lot of speed. With the
 * bit set on every CPU of the VM, FEX can leave that out (FEX_TSOENABLED=0).
 *
 * The bit is set on every online CPU, and on CPUs that come online later, and then left
 * alone: Linux itself never touches ACTLR_EL1, so it holds for every thread. Arm code keeps
 * running correctly (TSO is a stronger ordering), a little slower. Unloading the module
 * leaves the bit as it is: x86 programs may be relying on it; write 0 to `enabled` first.
 *
 * /sys/kernel/bottle_tso/
 *   offered   1: an Apple CPU whose hypervisor offers TSO (AIDR_EL1 bit 9)
 *   enabled   write 1 / 0 to set / clear the bit on every CPU; reads 1 when every online
 *             CPU has it
 *   cpus      one line per online CPU: "cpu N on|off ACTLR_EL1=0x..."
 *   info      MIDR_EL1 and AIDR_EL1 as the VM sees them
 * Module parameters: enable=1 sets it at load; force=1 tries even when it isn't offered.
 * At load the module tries the bit once on one CPU (and puts it back): bit_sticks in info.
 */
#include <linux/cpu.h>
#include <linux/cpuhotplug.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/smp.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>
#include <asm/barrier.h>
#include <asm/cputype.h>

#define ACTLR_TSOEN (1UL << 1)
#define AIDR_TSO (1UL << 9)
#define IMP_APPLE 0x61

static bool enable;
module_param(enable, bool, 0444);
MODULE_PARM_DESC(enable, "Set TSO on every CPU at load");
static bool force;
module_param(force, bool, 0444);
MODULE_PARM_DESC(force, "Try even when the hypervisor doesn't say it offers TSO");

static u64 read_actlr(void)
{
	u64 v;

	asm volatile("mrs %0, s3_0_c1_c0_1" : "=r"(v)); /* ACTLR_EL1 */
	return v;
}

static void write_actlr(u64 v)
{
	asm volatile("msr s3_0_c1_c0_1, %0" : : "r"(v));
	isb();
}

static u64 read_aidr(void)
{
	u64 v;

	asm volatile("mrs %0, s3_1_c0_c0_7" : "=r"(v)); /* AIDR_EL1 */
	return v;
}

static DEFINE_MUTEX(tso_lock);
static int hp_state = -1; /* the hotplug state while TSO is on, else -1 */
static bool offered, takes_bit; /* takes_bit: the probe write at load stuck */
static u64 midr, aidr;

/* Runs on the CPU in question (its hotplug thread): sets or clears the bit there. */
static int tso_cpu_on(unsigned int cpu)
{
	u64 v = read_actlr();

	if (!(v & ACTLR_TSOEN))
		write_actlr(v | ACTLR_TSOEN);
	if (!(read_actlr() & ACTLR_TSOEN)) {
		pr_warn("bottle_tso: cpu %u: TSO didn't stick (ACTLR_EL1=0x%llx)\n", cpu, read_actlr());
		return -EOPNOTSUPP;
	}
	return 0;
}

static int tso_cpu_off(unsigned int cpu)
{
	u64 v = read_actlr();

	if (v & ACTLR_TSOEN)
		write_actlr(v & ~ACTLR_TSOEN);
	return 0;
}

static long read_actlr_fn(void *unused)
{
	return (long)read_actlr();
}

/* Turns TSO on (every CPU, now and when one comes online) or off. Called with tso_lock. */
static int tso_set(bool on)
{
	int ret;

	if (!on) {
		if (hp_state >= 0) {
			cpuhp_remove_state(hp_state); /* runs tso_cpu_off on every online CPU */
			hp_state = -1;
			pr_info("bottle_tso: TSO off\n");
		}
		return 0;
	}
	if (hp_state >= 0)
		return 0;
	if (!takes_bit)
		return -EOPNOTSUPP;

	/* Every online CPU and any that comes online later. If one refuses, the others are
	 * undone (tso_cpu_off) and enabled reads 0. */
	ret = cpuhp_setup_state(CPUHP_AP_ONLINE_DYN, "bottle_tso:online", tso_cpu_on, tso_cpu_off);
	if (ret < 0) {
		pr_warn("bottle_tso: couldn't set TSO on every CPU (%d)\n", ret);
		return ret;
	}
	hp_state = ret;
	pr_info("bottle_tso: TSO on for every CPU\n");
	return 0;
}

/* ---- /sys/kernel/bottle_tso ---- */

static bool all_on(void)
{
	unsigned int cpu;
	bool ok = true;

	cpus_read_lock();
	for_each_online_cpu(cpu)
		if (!((u64)work_on_cpu(cpu, read_actlr_fn, NULL) & ACTLR_TSOEN))
			ok = false;
	cpus_read_unlock();
	return ok;
}

static ssize_t offered_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "%d\n", offered);
}

static ssize_t enabled_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "%d\n", all_on());
}

static ssize_t enabled_store(struct kobject *k, struct kobj_attribute *a, const char *buf, size_t n)
{
	bool on;
	int ret = kstrtobool(buf, &on);

	if (ret)
		return ret;
	mutex_lock(&tso_lock);
	ret = tso_set(on);
	mutex_unlock(&tso_lock);
	return ret ? ret : n;
}

static ssize_t cpus_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	unsigned int cpu;
	int len = 0;

	cpus_read_lock();
	for_each_online_cpu(cpu) {
		u64 v = (u64)work_on_cpu(cpu, read_actlr_fn, NULL);

		len += sysfs_emit_at(buf, len, "cpu %u %s ACTLR_EL1=0x%llx\n", cpu,
				     (v & ACTLR_TSOEN) ? "on" : "off", v);
	}
	cpus_read_unlock();
	return len;
}

static ssize_t info_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "MIDR_EL1=0x%llx AIDR_EL1=0x%llx implementer=0x%llx tso_offered=%d bit_sticks=%d\n",
			  midr, aidr, (midr >> 24) & 0xff, offered, takes_bit);
}

static struct kobj_attribute offered_attr = __ATTR_RO(offered);
static struct kobj_attribute enabled_attr = __ATTR(enabled, 0644, enabled_show, enabled_store);
static struct kobj_attribute cpus_attr = __ATTR_RO(cpus);
static struct kobj_attribute info_attr = __ATTR_RO(info);
static struct attribute *tso_attrs[] = {
	&offered_attr.attr, &enabled_attr.attr, &cpus_attr.attr, &info_attr.attr, NULL,
};
static const struct attribute_group tso_group = { .attrs = tso_attrs };
static struct kobject *tso_kobj;

/* At load, before any lock or sysfs file exists: if the hypervisor refuses the registers
 * (an undefined-instruction fault), only this module load fails, and nothing is left hanging.
 * One write of the bit on this CPU, read back, then the old value restored: whether the
 * hypervisor takes it at all. */
static void probe(void)
{
	u64 v0, v;
	int cpu;

	midr = read_cpuid_id();
	aidr = read_aidr();
	offered = ((midr >> 24) & 0xff) == IMP_APPLE && (aidr & AIDR_TSO);
	cpu = get_cpu();
	v0 = read_actlr();
	if (offered || force) {
		write_actlr(v0 | ACTLR_TSOEN);
		v = read_actlr();
		takes_bit = v & ACTLR_TSOEN;
		write_actlr(v0);
	}
	put_cpu();
	pr_info("bottle_tso: MIDR_EL1=0x%llx AIDR_EL1=0x%llx ACTLR_EL1=0x%llx (cpu %d): TSO %s%s\n",
		midr, aidr, v0, cpu, offered ? "offered" : "not offered",
		(offered || force) ? (takes_bit ? ", the bit sticks" : ", but the bit doesn't stick") : "");
}

static int __init bottle_tso_init(void)
{
	int ret;

	probe();

	tso_kobj = kobject_create_and_add("bottle_tso", kernel_kobj);
	if (!tso_kobj)
		return -ENOMEM;
	ret = sysfs_create_group(tso_kobj, &tso_group);
	if (ret) {
		kobject_put(tso_kobj);
		return ret;
	}
	if (enable) {
		mutex_lock(&tso_lock);
		ret = tso_set(true);
		mutex_unlock(&tso_lock);
		if (ret)
			pr_warn("bottle_tso: TSO stays off (%d)\n", ret);
	}
	return 0;
}

static void __exit bottle_tso_exit(void)
{
	/* sysfs first (it waits for a write in progress), then the hotplug callbacks, which go
	 * with the module: without tso_cpu_off running, the CPUs keep the bit
	 * (cpuhp_remove_state_nocalls), as x86 programs may rely on it. */
	sysfs_remove_group(tso_kobj, &tso_group);
	kobject_put(tso_kobj);
	mutex_lock(&tso_lock);
	if (hp_state >= 0)
		cpuhp_remove_state_nocalls(hp_state);
	hp_state = -1;
	mutex_unlock(&tso_lock);
}

module_init(bottle_tso_init);
module_exit(bottle_tso_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("x86-style memory ordering (Apple TSO) for every CPU of a Linux VM on a Mac");
