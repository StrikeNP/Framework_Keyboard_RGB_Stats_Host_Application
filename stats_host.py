import sys
import hid
import psutil
import batteryinfo
import subprocess

from prettyprinter import pprint

vendor_id     = 0x32ac
product_id    = 0x0012

usage_page    = 0xFF60
usage         = 0x61
report_length = 32

def get_raw_hid_interface():
    device_interfaces = hid.enumerate(vendor_id, product_id)
    raw_hid_interfaces = [i for i in device_interfaces if i['usage_page'] == usage_page and i['usage'] == usage]

    if len(raw_hid_interfaces) == 0:
        return None

    interface = hid.Device(path=raw_hid_interfaces[0]['path'])

    print(f"Manufacturer: {interface.manufacturer}")
    print(f"Product: {interface.product}")

    return interface

def send_raw_report(data):
    interface = get_raw_hid_interface()

    if interface is None:
        print("No device found")
        # sys.exit(1)

    request_data = [0x07] * (report_length + 1) # First byte is Report ID
    request_data[1:len(data) + 1] = data
    request_report = bytes(request_data)

    # print("Request:")
    # print(request_report)

    try:
        interface.write(request_report)

        response_report = interface.read(report_length, timeout=1000)

        # print("Response:")
        # print(response_report)
    finally:
        interface.close()

if __name__ == '__main__':


    battery = batteryinfo.Battery()

    while True:
        try:
            cpu_percent = round(psutil.cpu_percent(interval=1))
            memory_stats = psutil.virtual_memory()
            mem_percentage_used = round(memory_stats.percent)

            result = subprocess.run(['cat', '/sys/class/drm/card1/device/power_state'], stdout=subprocess.PIPE).stdout
            d3Cold = 1 if "D3cold" in str(result) else 0

            temp_stats = psutil.sensors_temperatures()
            cpu_temp = round(temp_stats["cros_ec"][3].current)
            print(f"CPU: {cpu_percent}% {cpu_temp}c\tRAM: {mem_percentage_used}\tGPU D3Cold: {d3Cold} ({result})")


            # pprint(temp_stats)
            print(f"Percent Full: {battery.percent}")
            print(f"State: {battery.state}")
            print(f"Energy Rate: {battery.energy_rate}")

            battery_percent = round(battery.percent.value)
            battery_watts = round(battery.energy_rate.value)
            discharging = 0xFF
            if battery.state == "Discharging": discharging = 1
            elif battery.state == "Charging": discharging = 0
            sys_data = [0x00, cpu_percent, mem_percentage_used, battery_watts, discharging, cpu_temp, d3Cold, battery_percent] # First byte is "channel id"
            # print(sys_data)
        
            send_raw_report(sys_data)
        except Exception as e:
            print(str(e))
            continue
        