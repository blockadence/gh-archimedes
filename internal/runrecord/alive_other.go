//go:build !unix

package runrecord

// Nowhere else can be asked this cheaply, and answering "alive" on a guess
// would hide every record there is behind "that run is still going".
//
// What answering "not alive" costs is the guard against acting on a record
// whose run is still under way, and it costs it on a platform where that
// run cannot be happening: the drivers archimedes ships are bash, and a
// driver that takes a snapshot at all takes it through them. So this is the
// same shape as interrupt_other.go — the driver layer here is somebody
// else's to supply, and so is this.
func processAlive(int) bool { return false }
