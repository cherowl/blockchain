package main

import (
    "bufio"
    "bytes"
	"encoding/json"
    "encoding/csv"
	"fmt"
    "io"
    "regexp"
	"strconv"
	"github.com/hyperledger/fabric/core/chaincode/shim"
	sc "github.com/hyperledger/fabric/protos/peer"
    "os"
)

type SmartContract struct {
}

type Machine struct {
	BusAndRoundID   string `json:"busAndRoundId"`
	VehicleID       string `json:"vehicleId"`
	DateOfTrip      string `json:"dateOfTrip"`
	TimestampOfTrip string `json:"timestampOfTrip"`
	TravelDistanceM string `json:"travelDistance_m"`
	TotalTimeSec    string `json:"totalTime_sec"`
}

func (s *SmartContract) Init(APIstub shim.ChaincodeStubInterface) sc.Response {
	return shim.Success(nil)
}

func constructQueryResponseFromIterator(resultsIterator shim.StateQueryIteratorInterface) (*bytes.Buffer, error) {
	// buffer is a JSON array containing QueryResults
	var buffer bytes.Buffer
	buffer.WriteString("[")

	bArrayMemberAlreadyWritten := false
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			return nil, err
		}
		// Add a comma before array members, suppress it for the first array member
		if bArrayMemberAlreadyWritten == true {
			buffer.WriteString(",")
		}
		buffer.WriteString("{\"Key\":")
		buffer.WriteString("\"")
		buffer.WriteString(queryResponse.Key)
		buffer.WriteString("\"")

		buffer.WriteString(", \"Record\":")
		// Record is a JSON object, so we write as-is
		buffer.WriteString(string(queryResponse.Value))
		buffer.WriteString("}")
		bArrayMemberAlreadyWritten = true
	}
	buffer.WriteString("]")

	return &buffer, nil
}

func getQueryResultForQueryString(stub shim.ChaincodeStubInterface, queryString string) ([]byte, error) {

	fmt.Printf("- getQueryResultForQueryString queryString:\n%s\n", queryString)

	resultsIterator, err := stub.GetQueryResult(queryString)
	if err != nil {
		return nil, err
	}
	defer resultsIterator.Close()

	buffer, err := constructQueryResponseFromIterator(resultsIterator)
	if err != nil {
		return nil, err
	}

	fmt.Printf("- getQueryResultForQueryString queryResult:\n%s\n", buffer.String())

	return buffer.Bytes(), nil
}


func getFormattedDateString(yearString string, monthString string, dayString string) string {
	year, _ := strconv.ParseFloat(yearString, 32)
	month, _ := strconv.ParseFloat(monthString, 32)
	day, _ := strconv.ParseFloat(dayString, 32)
    return fmt.Sprintf("%4.0f-%02.0f-%02.0f", year, month, day)
}


func (s *SmartContract) Invoke(APIstub shim.ChaincodeStubInterface) sc.Response {

	function, args := APIstub.GetFunctionAndParameters()
	if function == "queryBuses" {
		return s.queryBuses(APIstub, args)
	} else if function == "queryBusesByDate" {
		return s.queryBusesByDate(APIstub, args)
	} else if function == "initLedger" {
		return s.initLedger(APIstub)
	} else if function == "recordBus" {
		return s.recordBus(APIstub, args)
	} else if function == "recordBusesFromCSV" {
		return s.recordBusesFromCSV(APIstub, args)
	}
  return shim.Error(fmt.Sprintf("Invalid Smart Contract function name: %s", function))
}


func (s *SmartContract) queryBuses(APIstub shim.ChaincodeStubInterface, args []string) sc.Response {

	if len(args) != 1 {
		return shim.Error("Incorrect number of arguments. Expecting 1")
	}

	machineAsBytes, _ := APIstub.GetState(args[0])
	if machineAsBytes == nil {
		return shim.Error("Could not locate machine")
	}
	return shim.Success(machineAsBytes)
}


func (s *SmartContract) queryBusesByDate(APIstub shim.ChaincodeStubInterface, args []string) sc.Response {

	if len(args) != 1 {
		return shim.Error("Incorrect number of arguments. Expecting 1")
	}

    date := args[0]
    date_regex := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
    if !date_regex.MatchString(date) {
        return shim.Error("Date string not in a format YYYY-MM-DD")
    }

    queryString := fmt.Sprintf("{\"selector\":{\"dateOfTrip\":\"%s\"}}", date)
	queryResults, err := getQueryResultForQueryString(APIstub, queryString)

	if err != nil {
		return shim.Error(err.Error())
	}
	return shim.Success(queryResults)
}


func (s *SmartContract) initLedger(APIstub shim.ChaincodeStubInterface) sc.Response {
	machine := []Machine{

		Machine{
				VehicleID:"TESTT",
				DateOfTrip:"1000448",
				TimestampOfTrip:"args[3]",
				TravelDistanceM:"Adult",
				TotalTimeSec:"Bus",
			},
	}

	i := 0
	for i < len(machine) {
		fmt.Println("i is ", i)
		machineAsBytes, _ := json.Marshal(machine[i])
		APIstub.PutState(strconv.Itoa(i+1), machineAsBytes)
		fmt.Println("Added", machine[i])
		i = i + 1
	}

	return shim.Success(nil)
}

func (s *SmartContract) recordBus(APIstub shim.ChaincodeStubInterface, args []string) sc.Response {

		var machine = Machine {
					VehicleID:args[0],
					DateOfTrip:args[1],
					TimestampOfTrip:args[2],
					TravelDistanceM:args[3],
					TotalTimeSec:args[4],
		}
		// use to convert JSON to byte encoded data
		machineAsBytess, _ := json.Marshal(machine)
		txid := APIstub.GetTxID()
		compositeIndexName := "~VehicleID~DateOfTrip~txID"
		compositeKey, compositeErr := APIstub.CreateCompositeKey(compositeIndexName, []string{args[1], args[2], txid})

		// we put out data in ledger and database (args[0] is a key)
		err := APIstub.PutState(compositeKey, machineAsBytess)

		if err != nil {
			return shim.Error(fmt.Sprintf("Failed to record machine: %s", args[0],compositeErr.Error()))
		}
		return shim.Success(nil)
}


func (s *SmartContract) recordBusesFromCSV(APIstub shim.ChaincodeStubInterface, args []string) sc.Response {
	if len(args) < 1 {
		shim.Error("Incorrect number of arguments. Expecting (path to file) (Is header exists)[true/False]")
	}

    csvFile, error := os.Open(args[0])
    if error != nil {
        shim.Error(error.Error())
    }

    reader := csv.NewReader(bufio.NewReader(csvFile))

    var isHeaderLineParameter string
    if len(args) > 1 {
        isHeaderLineParameter := args[1]
        if (isHeaderLineParameter != "true" && isHeaderLineParameter != "false") {
            isHeaderLineParameter = "false"
        }
    } else {
        isHeaderLineParameter = "false"
    }

    isHeaderExists, _ := strconv.ParseBool(isHeaderLineParameter)

    for {
        line, error := reader.Read()
        if error != nil {
            shim.Error(error.Error())
        }
        if isHeaderExists {
            isHeaderExists = false
            continue
        }
        if error == io.EOF {
            break
        } else if error != nil {
            shim.Error(error.Error())
        }
        var dateString = getFormattedDateString(line[2], line[3], line[4])
        var machine = Machine {
                    VehicleID:line[1],
                    DateOfTrip:dateString,
                    TimestampOfTrip:line[9],
                    TravelDistanceM:line[10],
                    TotalTimeSec:line[18],
        }
        fmt.Println(machine)
		machineAsBytess, _ := json.Marshal(machine)
        txid := APIstub.GetTxID()
        compositeIndexName := "~VehicleID~DateOfTrip~txID"
        compositeKey, compositeErr := APIstub.CreateCompositeKey(compositeIndexName, []string{line[1], dateString, txid})

        // we put out data in ledger and database (args[0] is a key)
        err := APIstub.PutState(compositeKey, machineAsBytess)

        if err != nil {
            return shim.Error(fmt.Sprintf("Failed to record machine: %s", line[1],compositeErr.Error()))
        }
    }

    return shim.Success(nil)
}


func main() {

	// Create a new Smart Contract
	err := shim.Start(new(SmartContract))
	if err != nil {
		fmt.Printf("Error creating new Smart Contract: %s", err)
	}
}
