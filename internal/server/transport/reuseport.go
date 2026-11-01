package transport

import (
	"context"
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

// listenTCP binds a user port. With reuse it sets SO_REUSEPORT first, so a
// second tunnel can bind the same port while the first still holds it; the
// kernel then spreads new connections over both until one closes its listener.
// Without reuse it is exactly net.Listen.
func listenTCP(addr string, reuse bool) (net.Listener, error) {
	if !reuse {
		return net.Listen("tcp", addr)
	}
	lc := net.ListenConfig{Control: reusePortControl}
	return lc.Listen(context.Background(), "tcp", addr)
}

// listenUDP is listenTCP for the UDP side of a user port.
func listenUDP(addr string, reuse bool) (*net.UDPConn, error) {
	if !reuse {
		a, err := net.ResolveUDPAddr("udp", addr)
		if err != nil {
			return nil, err
		}
		return net.ListenUDP("udp", a)
	}
	lc := net.ListenConfig{Control: reusePortControl}
	pc, err := lc.ListenPacket(context.Background(), "udp", addr)
	if err != nil {
		return nil, err
	}
	return pc.(*net.UDPConn), nil
}

func reusePortControl(network, address string, c syscall.RawConn) error {
	var serr error
	if err := c.Control(func(fd uintptr) {
		serr = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEPORT, 1)
	}); err != nil {
		return err
	}
	return serr
}
