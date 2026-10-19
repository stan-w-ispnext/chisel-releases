rootfs="$(install-slices postgresql-18_bins)"

cleanup() {
  rc=$?
  if [ "${rc}" -ne 0 ]; then
    tail -n 50 "${rootfs}/data/log" 2>/dev/null || true
  fi
  chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_ctl -D /data stop -m immediate 2>/dev/null || true
}
trap cleanup EXIT

# ---- rootfs setup: users, /dev, writable dirs ----
chmod 755 "${rootfs}"
mkdir -p "${rootfs}"/{etc,tmp,data,dev/shm}
chmod 1777 "${rootfs}/tmp" "${rootfs}/dev/shm"
mknod -m 666 "${rootfs}/dev/null" c 1 3
mknod -m 666 "${rootfs}/dev/urandom" c 1 9
printf '%s\n' \
  'root:x:0:0::/root:/bin/sh' \
  'postgres:x:1001:1001::/data:/bin/sh' > "${rootfs}/etc/passwd"
chown 1001:1001 "${rootfs}/data"

bins="initdb oid2name pg_archivecleanup pg_checksums pg_controldata
  pg_createsubscriber pg_ctl pg_resetwal pg_rewind pg_test_fsync
  pg_test_timing pg_upgrade pg_waldump pg_walsummary pgbench
  postgres vacuumlo"
for bin in $bins; do
  test -x "${rootfs}/usr/lib/postgresql/18/bin/${bin}"
  chroot "${rootfs}" "/usr/lib/postgresql/18/bin/${bin}" --version | grep -q "(PostgreSQL) 18"
done

# ---- initdb + offline tools ----
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/initdb -D /data -U postgres --auth=trust --no-sync \
  -E UTF8 --locale=C --locale-provider=builtin --builtin-locale=C.UTF-8
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_controldata /data | grep -q "Database cluster state: *shut down"
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_checksums --check -D /data      # initdb enables checksums by default
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_resetwal --dry-run -D /data

# ---- start the server ----
printf '%s\n' \
  "listen_addresses = '127.0.0.1'" \
  "unix_socket_directories = '/tmp'" \
  "summarize_wal = on" \
  >> "${rootfs}/data/postgresql.conf"
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_ctl -D /data -l /data/log -w start
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_ctl -D /data status

# ---- client-style tools shipped in this package ----
export PGHOST=127.0.0.1 PGUSER=postgres
chroot "${rootfs}" /usr/lib/postgresql/18/bin/pgbench -i -s 1 postgres
chroot "${rootfs}" /usr/lib/postgresql/18/bin/pgbench -c 2 -t 20 postgres | grep -q "number of transactions actually processed: 40"
chroot "${rootfs}" /usr/lib/postgresql/18/bin/oid2name | grep -q postgres
chroot "${rootfs}" /usr/lib/postgresql/18/bin/vacuumlo postgres

# no psql in this slice: run SQL through pgbench -f
echo 'CHECKPOINT;' > "${rootfs}/tmp/checkpoint.sql"
chroot "${rootfs}" /usr/lib/postgresql/18/bin/pgbench -n -t 1 -f /tmp/checkpoint.sql postgres

# pg_walsummary: wait for the summarizer to write a file, then read it
for i in $(seq 30); do
  f="$(ls "${rootfs}"/data/pg_wal/summaries/* 2>/dev/null | head -n1 || true)"
  [ -n "${f}" ] && break
  sleep 1
done
test -n "${f}"
chroot "${rootfs}" /usr/lib/postgresql/18/bin/pg_walsummary "/data/pg_wal/summaries/$(basename "${f}")" | head

chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_ctl -D /data -w stop

# ---- offline tools that need a stopped cluster ----
seg="$(ls "${rootfs}"/data/pg_wal | grep -E '^[0-9A-F]{24}$' | head -n1)"
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_waldump -p /data/pg_wal "${seg}" | head

# pg_archivecleanup removes archived WAL older than the given segment
mkdir "${rootfs}/tmp/arch"
touch "${rootfs}/tmp/arch/000000010000000000000001" \
      "${rootfs}/tmp/arch/000000010000000000000002"
chroot "${rootfs}" /usr/lib/postgresql/18/bin/pg_archivecleanup /tmp/arch 000000010000000000000002
test ! -e "${rootfs}/tmp/arch/000000010000000000000001"
test -e "${rootfs}/tmp/arch/000000010000000000000002"

# benchmarks (short)
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_test_timing -d 1
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/pg_test_fsync -f /tmp/fsync.test -s 1

# pg_upgrade --check between two clusters of the same version
mkdir "${rootfs}/data2"
chown 1001:1001 "${rootfs}/data2"
chroot --userspec=1001:1001 "${rootfs}" /usr/lib/postgresql/18/bin/initdb -D /data2 -U postgres --auth=trust --no-sync \
  -E UTF8 --locale=C --locale-provider=builtin --builtin-locale=C.UTF-8
chroot --userspec=1001:1001 "${rootfs}" /bin/sh -c "cd /tmp && /usr/lib/postgresql/18/bin/pg_upgrade --check \
  -b /usr/lib/postgresql/18/bin -B /usr/lib/postgresql/18/bin -d /data -D /data2"