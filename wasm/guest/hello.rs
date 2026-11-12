#![no_std]
#![no_main]

extern "C" {
    fn print(char: u8);
}

#[no_mangle]
pub extern "C" fn _start() {
    let message = b"Hello, world!\n";
    let mut i = 0usize;
    while i < message.len() {
        unsafe {
            print(message[i]);
        }
        i += 1;
    }
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
